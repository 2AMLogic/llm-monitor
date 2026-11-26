import Foundation

/// Cumulative weekly quota consumption and hourly billable tokens for a provider.
struct ProviderUsageHistory {
    struct QuotaSample: Identifiable {
        let timestamp: Date
        let points: Double
        var id: Date { timestamp }
    }

    struct HourlyTokens: Identifiable {
        let timestamp: Date
        let count: Int64
        var id: Date { timestamp }
    }

    let range: ClosedRange<Date>
    let quota: [QuotaSample]
    let tokens: [HourlyTokens]

    static func load(db: Connection, provider: AccountProvider, now: Date) throws -> Self {
        let hour: TimeInterval = 3600
        let currentHour = floor(now.timeIntervalSince1970 / hour) * hour
        let start = Date(timeIntervalSince1970: currentHour - 167 * hour)
        let range = start...now
        let quota = try loadQuota(db: db, provider: provider, range: range)
        try Task.checkCancellation()
        return Self(range: range, quota: quota, tokens: try loadTokens(db: db, provider: provider, range: range))
    }

    private struct WeeklyReading {
        let at: Date
        let percent: Double
        let resetAt: Date?

        func increase(since previous: Self) -> Double {
            // A complete rollover between polls can leave the next percentage
            // higher than the previous one, so there may be no synthetic zero.
            if let end = previous.resetAt, previous.at < end, end <= at,
               let nextEnd = resetAt, at < nextEnd {
                return percent
            }
            return max(0, percent - previous.percent)
        }
    }

    // SQLite orders the two stored ISO shapes by instant, including fractions.
    // Round the converted Julian day back to the source millisecond resolution.
    private static func date(_ julianDay: Any?) -> Date? {
        guard let value = julianDay as? Double else { return nil }
        return Date(timeIntervalSince1970: ((value - 2440587.5) * 86_400_000).rounded() / 1000)
    }

    private static func loadQuota(
        db: Connection, provider: AccountProvider, range: ClosedRange<Date>
    ) throws -> [QuotaSample] {
        // As in quota calibration, seed each account's first delta from the
        // preceding day. An account with no predecessor starts at its first reading.
        let formatter = ISO8601DateFormatter()
        let seedStart = range.lowerBound.addingTimeInterval(-86_400)
        let rows = try db.prepare("""
            SELECT u.account_id, julianday(u.timestamp), u.weekly_all_percent,
                   julianday(u.weekly_reset), IFNULL(u.is_synthetic, 0)
            FROM usage_history u JOIN accounts a ON a.id = u.account_id
            WHERE u.timestamp >= ? AND u.timestamp < ? AND a.provider = ?
              AND u.weekly_all_percent IS NOT NULL
              AND (IFNULL(u.is_synthetic, 0) = 0 OR u.weekly_all_percent = 0)
            ORDER BY julianday(u.timestamp), u.id
            """).bind(String(formatter.string(from: seedStart).dropLast()),
                      String(formatter.string(from: range.upperBound.addingTimeInterval(1)).dropLast()),
                      provider.rawValue)

        var previous: [String: WeeklyReading] = [:]
        var total = 0.0
        var hasReading = false
        var samples: [QuotaSample] = []
        var next = rows.next()
        var at = range.lowerBound
        while true {
            try Task.checkCancellation()
            while let row = next {
                guard let observed = date(row[1]), let account = row[0] as? String,
                      let percent = row[2] as? Double else {
                    next = rows.next()
                    continue
                }
                if observed > at { break }
                let reading = WeeklyReading(at: observed, percent: percent, resetAt: date(row[3]))
                let prior = previous.updateValue(reading, forKey: account)
                // A synthetic zero sets the new baseline before the real row at
                // the same instant. Only real, in-range observations add spend.
                if observed >= range.lowerBound, row[4] as? Int64 == 0 {
                    hasReading = true
                    if let prior { total += reading.increase(since: prior) }
                }
                next = rows.next()
            }
            samples.append(QuotaSample(timestamp: at, points: total))
            if at == range.upperBound { break }
            at = min(at.addingTimeInterval(3600), range.upperBound)
        }
        return hasReading ? samples : []
    }

    private static func loadTokens(db: Connection, provider: AccountProvider, range: ClosedRange<Date>) throws -> [HourlyTokens] {
        // Most imports lack an account mapping. Group by hour and model before
        // resolving their provider, so message-level rows never reach the UI.
        let rows = try db.prepare("""
            SELECT strftime('%Y-%m-%dT%H:00:00Z', u.timestamp) AS hour, a.provider, u.model,
                   SUM(IFNULL(u.input_tokens, 0) + IFNULL(u.output_tokens, 0) + IFNULL(u.cache_creation_tokens, 0))
            FROM token_usage u
            LEFT JOIN token_sessions s ON s.session_id = u.session_id
            LEFT JOIN token_sessions p ON p.session_id = s.parent_session_id
            LEFT JOIN accounts a ON a.id = COALESCE(s.override_account_id, p.override_account_id, s.inferred_account_id)
            WHERE u.timestamp >= ? AND julianday(u.timestamp) <= julianday(?, 'unixepoch')
            GROUP BY hour, a.provider, u.model
            """)
        // The lower bound is on an exact hour. Omit the trailing Z so both
        // ISO timestamp shapes in that second are included by the index.
        let start = String(ISO8601DateFormatter().string(from: range.lowerBound).dropLast())
        var sums: [Date: Int64] = [:]
        for row in rows.bind(start, range.upperBound.timeIntervalSince1970) {
            let recordedProvider = (row[1] as? String).flatMap(AccountProvider.init(rawValue:))
                ?? providerForModel(row[2] as? String)
            guard recordedProvider == provider else { continue }
            if let hour = UsageRecord.parseISO(row[0] as? String), let count = row[3] as? Int64 {
                sums[hour, default: 0] += count
            }
        }
        return sums.sorted { $0.key < $1.key }.map { HourlyTokens(timestamp: $0.key, count: $0.value) }
    }

    private static func providerForModel(_ model: String?) -> AccountProvider? {
        guard let name = model?.lowercased().split(separator: "/").last else { return nil }
        if name.hasPrefix("claude-") { return .anthropic }
        if name.hasPrefix("glm-") { return .zai }
        if name.hasPrefix("gpt-") || name.hasPrefix("codex-") { return .openai }
        let family = name.split(separator: "-").first
        if family == "o1" || family == "o3" || family == "o4" { return .openai }
        return nil
    }
}
