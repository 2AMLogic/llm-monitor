#if os(macOS)
import SwiftUI
import Charts

/// Chart display mode
enum ChartMode: String, CaseIterable {
    case percent = "% of Quota"
    case tokens = "Tokens"
    /// Daily `tokens_per_point` (#199, visualizing #198's
    /// `quota_calibration_daily`) — "how much did one weekly rate-limit point
    /// cost, in tokens, on this day".
    case calibration = "Tokens/Point"
}

/// Data for a single account's chart trace
struct AccountTrace: Identifiable {
    let id: String
    let name: String
    let dataPoints: [UsageDataPoint]
    let color: Color
    let isPrimary: Bool
}

/// Token trace for a single account
struct TokenTrace: Identifiable {
    let id: String
    let name: String
    let dataPoints: [TokenDataPoint]
    let color: Color
    let isPrimary: Bool
}

/// One named sub-limit's overlay series (e.g. an OpenAI
/// `additional_rate_limits[]` entry). Named by the provider — the label is
/// used verbatim, never mapped to a fixed enum, since naming will churn.
struct NamedLimitTrace: Identifiable {
    let id: String  // the provider's limit_name, doubling as a stable-enough series key
    let name: String
    let dataPoints: [NamedLimitDataPoint]
    let color: Color
}

private struct ChartHistory {
    let dataPoints: [UsageDataPoint]
    let latest: FullUsageDataPoint?
    let tokenDataPoints: [TokenDataPoint]
    let tokenDataIsHostTotal: Bool
    let calibrationDataPoints: [CalibrationDataPoint]
    let namedLimitTraces: [NamedLimitTrace]
    let latestComparison: Date?
    let sessionEstimate: (minutes: Double, limitType: String)?
    let weeklyEstimate: (minutes: Double, limitType: String)?

    // A nonisolated async load runs on the generic executor. Only the completed
    // snapshot crosses back to SwiftUI, including the fits reused on redraw.
    static func load(for accountId: String, accounts: [Account], store: UsageStore) async throws -> ChartHistory {
        try Task.checkCancellation()
        let data = store.loadHistory(for: accountId)
        let full = store.loadFullHistory(for: accountId)
        try Task.checkCancellation()
        let attributed = store.loadTokenHistory(for: accountId)
        let useHostTotal = attributed.isEmpty && store.hasAnyTokenUsageData()
        let tokens = useHostTotal ? store.loadHostTotalTokenHistory() : attributed
        try Task.checkCancellation()
        let limits = store.loadNamedLimitHistory(for: accountId).sorted { $0.key < $1.key }
        let colors = ChartWindowController.namedLimitColors
        let namedTraces = limits.enumerated().map { index, limit in
            NamedLimitTrace(id: limit.key, name: limit.key,
                            dataPoints: limit.value.sorted { $0.timestamp < $1.timestamp },
                            color: colors[index % colors.count])
        }
        let session = full.compactMap { point in point.sessionPercent.map { (point.timestamp, $0) } }
        let weekly = full.compactMap { point in point.weeklyAllPercent.map { (point.timestamp, $0) } }
        return ChartHistory(
            dataPoints: data, latest: full.last,
            tokenDataPoints: tokens, tokenDataIsHostTotal: useHostTotal,
            calibrationDataPoints: store.loadCalibrationHistory(for: accountId),
            namedLimitTraces: namedTraces,
            latestComparison: store.latestComparisonTimestamp(among: Set(accounts.map(\.id)).subtracting([accountId])),
            sessionEstimate: estimateTimeToLimit(points: session, limitName: "session limits"),
            weeklyEstimate: estimateTimeToLimit(points: weekly, limitName: "weekly limits")
        )
    }

    /// Linear regression result: slope (percent per minute) and intercept
    private struct LinearFit {
        let slope: Double      // percent per minute (positive = increasing usage)
        let intercept: Double  // percent at time 0
        let r2: Double         // R-squared (quality of fit)
    }

    /// Helper to compute linear regression from x,y arrays
    private static func computeRegression(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double)? {
        let n = Double(xs.count)
        guard n >= 2 else { return nil }

        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map { $0 * $1 }.reduce(0, +)
        let sumX2 = xs.map { $0 * $0 }.reduce(0, +)

        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return nil }

        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n
        return (slope, intercept)
    }

    /// Fit a line to usage data using robust regression with 3σ outlier exclusion.
    /// Starts from the most recent points and iteratively adds earlier points,
    /// stopping when a point would be a statistical outlier.
    private static func fitLinearModel(points: [(Date, Double)]) -> LinearFit? {
        guard points.count >= 2 else { return nil }

        // Use the most recent point as time reference (x=0 at the end)
        let baseTime = points.last!.0.timeIntervalSince1970

        // Convert all points to (x, y) where x is minutes before now (negative values)
        let allXY: [(x: Double, y: Double)] = points.map { point in
            let x = (point.0.timeIntervalSince1970 - baseTime) / 60.0
            return (x, point.1)
        }

        // Start with the last 2 points
        var includedIndices: [Int] = [allXY.count - 1, allXY.count - 2]

        // Iteratively try to add earlier points
        for i in stride(from: allXY.count - 3, through: 0, by: -1) {
            let candidate = allXY[i]

            // First check: candidate's y must be <= the earliest included point's y
            // (usage should not decrease going forward in time)
            let earliestIncluded = allXY[includedIndices.last!]
            if candidate.y > earliestIncluded.y {
                // Reset detected, stop here
                break
            }

            // Get current included points
            let currentXs = includedIndices.map { allXY[$0].x }
            let currentYs = includedIndices.map { allXY[$0].y }

            // Fit line to current points
            guard let regression = computeRegression(xs: currentXs, ys: currentYs) else { break }

            // Calculate residuals and standard deviation for current points
            let residuals = zip(currentXs, currentYs).map { x, y in
                y - (regression.slope * x + regression.intercept)
            }
            let meanResidual = residuals.reduce(0, +) / Double(residuals.count)
            let variance = residuals.map { pow($0 - meanResidual, 2) }.reduce(0, +) / Double(residuals.count)
            let stdDev = sqrt(variance)

            // Calculate predicted value and residual for candidate
            let predictedY = regression.slope * candidate.x + regression.intercept
            let candidateResidual = candidate.y - predictedY

            // Check if candidate is within 3σ (use max of stdDev and 1.0 to handle low-variance cases)
            let threshold = max(stdDev, 1.0) * 3.0
            if abs(candidateResidual) <= threshold {
                // Point is consistent with the trend, include it
                includedIndices.append(i)
            } else {
                // Point is an outlier, stop adding more
                break
            }
        }

        guard includedIndices.count >= 2 else { return nil }

        // Final regression on all included points
        let finalXs = includedIndices.map { allXY[$0].x }
        let finalYs = includedIndices.map { allXY[$0].y }

        guard let finalRegression = computeRegression(xs: finalXs, ys: finalYs) else { return nil }

        // Calculate R-squared
        let meanY = finalYs.reduce(0, +) / Double(finalYs.count)
        let ssTotal = finalYs.map { pow($0 - meanY, 2) }.reduce(0, +)
        let ssResidual = zip(finalXs, finalYs).map { x, y in
            pow(y - (finalRegression.slope * x + finalRegression.intercept), 2)
        }.reduce(0, +)
        let r2 = ssTotal > 0 ? 1 - ssResidual / ssTotal : 0

        return LinearFit(slope: finalRegression.slope, intercept: finalRegression.intercept, r2: r2)
    }

    /// Estimate time until a usage metric reaches 100%
    private static func estimateTimeToLimit(points: [(Date, Double)], limitName: String) -> (minutes: Double, limitType: String)? {
        guard let fit = fitLinearModel(points: points) else { return nil }

        // Need positive slope (increasing usage) to estimate exhaustion
        guard fit.slope > 0.001 else { return nil }  // At least 0.001% per minute

        // Get current percent (last point)
        guard let currentPercent = points.last?.1 else { return nil }

        // Time to reach 100%
        let remaining = 100.0 - currentPercent
        guard remaining > 0 else { return (0, limitName) }

        let minutesToExhaust = remaining / fit.slope
        return (minutesToExhaust, limitName)
    }
}

private struct ChartComparisons {
    var accounts: [AccountTrace] = []
    var tokens: [TokenTrace] = []

    static func load(for accountId: String, accounts: [Account], store: UsageStore) async throws -> Self {
        try Task.checkCancellation()
        var result = Self()
        let colors = ChartWindowController.otherAccountColors
        let tokens = store.loadTokenHistoryByAccount()
        for (index, account) in accounts.enumerated() where account.id != accountId {
            try Task.checkCancellation()
            let color = colors[index % colors.count]
            let points = store.loadHistory(for: account.id)
            if !points.isEmpty {
                result.accounts.append(AccountTrace(id: account.id, name: account.displayName,
                                                    dataPoints: points, color: color, isPrimary: false))
            }
            if let points = tokens[account.id] {
                result.tokens.append(TokenTrace(id: account.id, name: account.displayName,
                                                dataPoints: points, color: color, isPrimary: false))
            }
        }
        return result
    }
}

private struct ChartHistoryLoader: View {
    let account: Account
    let accounts: [Account]
    let store: UsageStore
    let oauthPoller: OAuthPoller?
    @State private var history: ChartHistory?

    var body: some View {
        Group {
            if let history {
                UsageChartWindow(account: account, accounts: accounts, history: history,
                                 store: store, oauthPoller: oauthPoller)
            } else {
                ProgressView("Loading usage history…")
                    .frame(width: 620, height: 610)
            }
        }
        .task {
            guard history == nil,
                  let loaded = try? await ChartHistory.load(for: account.id, accounts: accounts, store: store),
                  !Task.isCancelled else { return }
            history = loaded
        }
    }
}

private struct UsageChartWindow: View {
    let account: Account
    let accounts: [Account]
    let history: ChartHistory
    let store: UsageStore
    let oauthPoller: OAuthPoller?
    @State private var comparisons: ChartComparisons?
    private var otherAccountsData: [AccountTrace] { comparisons?.accounts ?? [] }
    private var otherTokenData: [TokenTrace] { comparisons?.tokens ?? [] }
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var updateChecker = UpdateChecker.shared
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var displayName: String = ""
    @State private var isNameHovering = false
    @State private var showClearConfirmation = false
    @State private var rangeStart: Double = 0.0  // 0-1 percentage of 7-day range
    @State private var rangeEnd: Double = 1.0    // 0-1 percentage of 7-day range
    @State private var hasInitializedRange = false
    @State private var showOtherAccounts = false
    @State private var chartMode: ChartMode = .percent

    /// The 7-day window: ends at the latest data point (or now), starts 7 days before
    var chartDateRange: (start: Date, end: Date) {
        let primaryEnd = history.dataPoints.last?.timestamp ?? Date()
        let latestDate = max(primaryEnd, history.latestComparison ?? primaryEnd)
        let sevenDaysAgo = latestDate.addingTimeInterval(-7 * 24 * 60 * 60)
        return (sevenDaysAgo, latestDate)
    }

    /// Initial range values to show just the active account's data within the 7-day window
    var initialRangeForActiveAccount: (start: Double, end: Double) {
        let (windowStart, windowEnd) = chartDateRange
        let windowInterval = windowEnd.timeIntervalSince(windowStart)
        guard windowInterval > 0,
              let firstData = history.dataPoints.first?.timestamp,
              let lastData = history.dataPoints.last?.timestamp else {
            return (0.0, 1.0)
        }
        // Calculate where active account's data falls within the 7-day window
        let startPos = max(0, firstData.timeIntervalSince(windowStart) / windowInterval)
        let endPos = min(1, lastData.timeIntervalSince(windowStart) / windowInterval)
        // Add small padding (2% on each side)
        let padding = 0.02
        return (max(0, startPos - padding), min(1, endPos + padding))
    }

    /// Filtered data points based on current range selection
    var filteredDataPoints: [UsageDataPoint] {
        guard history.dataPoints.count >= 2 else { return history.dataPoints }
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)
        return history.dataPoints.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Filtered other accounts data based on current range selection
    var filteredOtherAccounts: [AccountTrace] {
        guard !otherAccountsData.isEmpty else { return [] }
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)
        return otherAccountsData.map { trace in
            AccountTrace(
                id: trace.id,
                name: trace.name,
                dataPoints: trace.dataPoints.filter { $0.timestamp >= startDate && $0.timestamp <= endDate },
                color: trace.color,
                isPrimary: trace.isPrimary
            )
        }
    }

    /// Filtered token data points based on current range selection
    var filteredTokenDataPoints: [TokenDataPoint] {
        guard history.tokenDataPoints.count >= 2 else { return history.tokenDataPoints }
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)
        return history.tokenDataPoints.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Filtered other accounts token data based on current range selection
    var filteredOtherTokenData: [TokenTrace] {
        guard !otherTokenData.isEmpty else { return [] }
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)
        return otherTokenData.map { trace in
            TokenTrace(
                id: trace.id,
                name: trace.name,
                dataPoints: trace.dataPoints.filter { $0.timestamp >= startDate && $0.timestamp <= endDate },
                color: trace.color,
                isPrimary: trace.isPrimary
            )
        }
    }

    /// Filtered named-limit traces based on the current range selection.
    /// Empty when the account has no named limits — callers must check this
    /// before rendering anything so the overlay stays entirely hidden.
    var filteredNamedLimitTraces: [NamedLimitTrace] {
        guard !history.namedLimitTraces.isEmpty else { return [] }
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)
        return history.namedLimitTraces.map { trace in
            NamedLimitTrace(
                id: trace.id,
                name: trace.name,
                dataPoints: trace.dataPoints.filter { $0.timestamp >= startDate && $0.timestamp <= endDate },
                color: trace.color
            )
        }
    }

    /// Filtered calibration data points based on the current range selection.
    var filteredCalibrationDataPoints: [CalibrationDataPoint] {
        guard history.calibrationDataPoints.count >= 2 else { return history.calibrationDataPoints }
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)
        return history.calibrationDataPoints.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Maximum `tokensPerPoint` value in the filtered range (for Y-axis
    /// scaling), with 10% headroom so the topmost point isn't drawn flush
    /// against the axis. `1` when there is nothing to plot — `chartYScale`
    /// still needs a non-zero domain even though the empty-state view (not
    /// the chart) is what actually renders in that case.
    var maxCalibrationValue: Double {
        let maxVal = filteredCalibrationDataPoints.map(\.tokensPerPoint).max() ?? 0
        return maxVal > 0 ? maxVal * 1.1 : 1
    }

    /// Whether this account has any calibration data to plot at all — gates
    /// the `.calibration` mode out of the picker exactly as `hasTokenData`
    /// already gates `.tokens`.
    var hasCalibrationData: Bool {
        !history.calibrationDataPoints.isEmpty
    }

    /// Modes actually worth offering for this account. `.percent` is always
    /// present (it is what `history.dataPoints` — already asserted non-empty above —
    /// backs); `.tokens` and `.calibration` are offered only when there is
    /// data for them, so a mode with nothing to show is never reachable.
    var availableChartModes: [ChartMode] {
        var modes: [ChartMode] = [.percent]
        if hasTokenData { modes.append(.tokens) }
        if hasCalibrationData { modes.append(.calibration) }
        return modes
    }

    /// The one headline the chart section shows, covering every `ChartMode`.
    /// `.tokens` defers to `tokenChartTitle` so the #201 host-total
    /// qualification is spelled in exactly one place; `.calibration` is
    /// deliberately *not* qualified that way — a tokens-per-point figure is a
    /// pool-scope ratio computed by `QuotaCalibration`, not this account's
    /// attributed spend, so the host-total caveat does not apply to it.
    var chartModeHeadline: String {
        switch chartMode {
        case .percent: return "Weekly Usage"
        case .tokens: return tokenChartTitle
        case .calibration: return "Tokens per Point"
        }
    }

    /// Maximum token value in the filtered range (for Y-axis scaling)
    var maxTokenValue: Int64 {
        var maxVal: Int64 = 0
        for point in filteredTokenDataPoints {
            maxVal = max(maxVal, point.billableTokens)
        }
        if showOtherAccounts {
            for trace in filteredOtherTokenData {
                for point in trace.dataPoints {
                    maxVal = max(maxVal, point.billableTokens)
                }
            }
        }
        // Round up to a nice number
        let magnitude = max(1, Int64(pow(10, floor(log10(Double(max(1, maxVal)))))))
        return ((maxVal / magnitude) + 1) * magnitude
    }

    /// Check if we have token data to display
    var hasTokenData: Bool {
        !history.tokenDataPoints.isEmpty
    }

    /// Token chart section title — distinguishes a genuine per-account series
    /// from the #201 host-total fallback so the two are never visually
    /// indistinguishable.
    var tokenChartTitle: String {
        history.tokenDataIsHostTotal ? "Token Usage (Host Total)" : "Token Usage"
    }

    /// Convert range position (0-1) to actual date within 7-day window
    func dateForRangePosition(_ position: Double) -> Date {
        let (windowStart, windowEnd) = chartDateRange
        let totalInterval = windowEnd.timeIntervalSince(windowStart)
        return windowStart.addingTimeInterval(totalInterval * position)
    }

    /// Generate midnight dates within the visible range
    var midnightDates: [Date] {
        let calendar = Calendar.current
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)

        // Find first midnight at or after start
        var current = calendar.startOfDay(for: startDate)
        if current < startDate {
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
        }

        var dates: [Date] = []
        while current <= endDate {
            dates.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
        }
        return dates
    }

    /// Generate 4-hour marks within the visible range (excluding midnights)
    var fourHourDates: [Date] {
        let calendar = Calendar.current
        let startDate = dateForRangePosition(rangeStart)
        let endDate = dateForRangePosition(rangeEnd)

        // Find first 4-hour boundary at or after start
        let startHour = calendar.component(.hour, from: startDate)
        let nextFourHour = ((startHour / 4) + 1) * 4
        var current = calendar.startOfDay(for: startDate)
        current = calendar.date(byAdding: .hour, value: nextFourHour, to: current) ?? current

        var dates: [Date] = []
        while current <= endDate {
            let hour = calendar.component(.hour, from: current)
            if hour != 0 {  // Skip midnights
                dates.append(current)
            }
            current = calendar.date(byAdding: .hour, value: 4, to: current) ?? current
        }
        return dates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingName {
                        HStack(spacing: 8) {
                            TextField("Account name", text: $editedName)
                                .textFieldStyle(.plain)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .onSubmit { saveNameEdit() }
                                .onExitCommand { isEditingName = false }

                            Button(action: saveNameEdit) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)

                            Button(action: { isEditingName = false }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 6) {
                            if isNameHovering {
                                Button(action: {
                                    editedName = displayName
                                    isEditingName = true
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(displayName)
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .onHover { hovering in
                            isNameHovering = hovering
                        }
                    }
                    HStack(spacing: 6) {
                        if let plan = account.plan {
                            Text(plan)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        // Token status in chart header (M4.4)
                        if let poller = oauthPoller,
                           let status = poller.credentialStatuses.first(where: { $0.accountId == account.id }) {
                            Circle()
                                .fill(tokenStatusColor(status.status))
                                .frame(width: 8, height: 8)
                            if let lastPoll = status.lastPoll {
                                Text("Polled \(pollTimeAgo(lastPoll))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Spacer()
                // Show session and weekly percentages with labels
                VStack(alignment: .trailing, spacing: 4) {
                    if let sessionPercent = latestSessionPercent {
                        HStack(spacing: 4) {
                            Text("Session")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(Int(sessionPercent))%")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(PercentSeverity(percent: sessionPercent).color)
                        }
                    }
                    if let weeklyPercent = latestWeeklyPercent {
                        HStack(spacing: 4) {
                            Text("Weekly")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(Int(weeklyPercent))%")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(PercentSeverity(percent: weeklyPercent).color)
                        }
                    }
                }
            }
            .padding(.bottom, 8)

            if history.dataPoints.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No usage history yet")
                        .font(.headline)
                    Text("History builds up as LLM Monitor polls this account.\nCheck back after a few poll cycles.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Usage chart with mode toggle
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(chartModeHeadline)
                            .font(.headline)
                        Spacer()

                        // Chart mode toggle — `.tokens`/`.calibration` only
                        // appear once there is actually data for them (#199
                        // mirrors the pre-existing `.tokens` gate below), so
                        // an account with neither never offers a mode with
                        // nothing to show.
                        if availableChartModes.count > 1 {
                            Picker("", selection: $chartMode) {
                                ForEach(availableChartModes, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: availableChartModes.count > 2 ? 230 : 160)
                        }

                        if history.latestComparison != nil {
                            Button(action: { showOtherAccounts.toggle() }) {
                                HStack(spacing: 4) {
                                    if showOtherAccounts && comparisons == nil {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: showOtherAccounts ? "eye.fill" : "eye.slash")
                                            .font(.caption)
                                    }
                                    Text(showOtherAccounts ? "Hide others" : "Show others")
                                        .font(.caption)
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // #201: a host-total fallback stands in for per-account
                    // attribution when nothing has been attributed yet (every
                    // freshly-imported transcript leaves
                    // token_sessions.inferred_account_id NULL by design —
                    // see UsageStore.loadHostTotalTokenHistory). Must be
                    // labeled every time it's shown so it's never mistaken
                    // for this account's own spend.
                    if chartMode == .tokens && history.tokenDataIsHostTotal {
                        Text("Not yet attributed to a specific account — shown as a host-wide total.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if chartMode == .percent {
                    Chart {
                        // Other accounts (rendered first so primary is on top)
                        if showOtherAccounts {
                            ForEach(filteredOtherAccounts) { trace in
                                ForEach(trace.dataPoints) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Usage %", point.weeklyPercent),
                                        series: .value("Account", trace.id)
                                    )
                                    .foregroundStyle(trace.color)
                                    .opacity(0.6)

                                    PointMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Usage %", point.weeklyPercent)
                                    )
                                    .foregroundStyle(trace.color)
                                    .opacity(0.6)
                                    .symbolSize(20)
                                }
                            }
                        }

                        // Named per-model sub-limits (OpenAI additional_rate_limits[]),
                        // drawn beneath the primary trace. Empty (and therefore
                        // invisible) for every account with no named limits.
                        ForEach(filteredNamedLimitTraces) { trace in
                            ForEach(trace.dataPoints) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Usage %", point.usedPercent),
                                    series: .value("NamedLimit", trace.id)
                                )
                                .foregroundStyle(trace.color)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                                PointMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Usage %", point.usedPercent)
                                )
                                .foregroundStyle(trace.color)
                                .symbolSize(15)
                            }
                        }

                        // Primary account (blue)
                        ForEach(filteredDataPoints) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Usage %", point.weeklyPercent),
                                series: .value("Account", "primary")
                            )
                            .foregroundStyle(Color.blue)

                            PointMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Usage %", point.weeklyPercent)
                            )
                            .foregroundStyle(Color.blue)
                            .symbolSize(30)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXScale(domain: dateForRangePosition(rangeStart)...dateForRangePosition(rangeEnd))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let percent = value.as(Int.self) {
                                    Text("\(percent)%")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        // Major ticks at midnight with MM/DD labels
                        AxisMarks(values: midnightDates) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(formatDateShort(date))
                                        .font(.caption)
                                }
                            }
                        }
                        // Minor ticks every 4 hours with dashed lines, no labels
                        AxisMarks(values: fourHourDates) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                        }
                    }
                    .frame(height: 220)
                    } else if chartMode == .tokens {
                        // Token chart
                        Chart {
                            // Other accounts tokens (rendered first so primary is on top)
                            if showOtherAccounts {
                                ForEach(filteredOtherTokenData) { trace in
                                    ForEach(trace.dataPoints) { point in
                                        BarMark(
                                            x: .value("Time", point.timestamp),
                                            y: .value("Tokens", point.billableTokens),
                                            width: .fixed(8)
                                        )
                                        .foregroundStyle(trace.color)
                                        .opacity(0.6)
                                    }
                                }
                            }

                            // Primary account tokens (blue bars - matches percent chart)
                            ForEach(filteredTokenDataPoints) { point in
                                BarMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Tokens", point.billableTokens),
                                    width: .fixed(10)
                                )
                                .foregroundStyle(Color.blue)
                            }
                        }
                        .chartYScale(domain: 0...Double(maxTokenValue))
                        .chartXScale(domain: dateForRangePosition(rangeStart)...dateForRangePosition(rangeEnd))
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let tokens = value.as(Double.self) {
                                        Text(formatTokenCount(Int64(tokens)))
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: midnightDates) { value in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                                AxisValueLabel {
                                    if let date = value.as(Date.self) {
                                        Text(formatDateShort(date))
                                            .font(.caption)
                                    }
                                }
                            }
                            AxisMarks(values: fourHourDates) { _ in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            }
                        }
                        .frame(height: 220)
                    } else if history.calibrationDataPoints.isEmpty {
                        // Calibration mode with nothing to plot (#199) —
                        // unreachable via the picker (it's gated out of
                        // `availableChartModes`), kept as a defensive
                        // fallback rather than rendering an empty `Chart`.
                        VStack(spacing: 12) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No calibration data yet")
                                .font(.headline)
                            Text("Needs both usage history and token history\nfor this account")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(height: 220)
                    } else {
                        // Calibration chart (#199): daily tokens-per-point.
                        Chart {
                            ForEach(filteredCalibrationDataPoints) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Tokens/Point", point.tokensPerPoint),
                                    series: .value("Account", "primary")
                                )
                                .foregroundStyle(Color.blue)

                                PointMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Tokens/Point", point.tokensPerPoint)
                                )
                                .foregroundStyle(Color.blue)
                                .symbolSize(30)
                            }
                        }
                        .chartYScale(domain: 0...maxCalibrationValue)
                        .chartXScale(domain: dateForRangePosition(rangeStart)...dateForRangePosition(rangeEnd))
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let tokensPerPoint = value.as(Double.self) {
                                        Text(String(format: "%.0f", tokensPerPoint))
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: midnightDates) { value in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                                AxisValueLabel {
                                    if let date = value.as(Date.self) {
                                        Text(formatDateShort(date))
                                            .font(.caption)
                                    }
                                }
                            }
                            AxisMarks(values: fourHourDates) { _ in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            }
                        }
                        .frame(height: 220)
                    }

                    // Legend for other accounts
                    if showOtherAccounts && !otherAccountsData.isEmpty {
                        HStack(spacing: 16) {
                            // Primary account
                            HStack(spacing: 4) {
                                Circle().fill(Color.blue).frame(width: 8, height: 8)
                                Text(displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            // Other accounts
                            ForEach(otherAccountsData) { trace in
                                HStack(spacing: 4) {
                                    Circle().fill(trace.color).frame(width: 8, height: 8)
                                    Text(trace.name)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Legend for named per-model sub-limits — only rendered when the
                    // account actually has at least one, so an Anthropic account (or
                    // an OpenAI account before this shipped) shows nothing extra.
                    if chartMode == .percent && !history.namedLimitTraces.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(history.namedLimitTraces) { trace in
                                HStack(spacing: 4) {
                                    Rectangle()
                                        .fill(trace.color)
                                        .frame(width: 10, height: 2)
                                    Text(trace.name)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }

                    // Range selector (always show if we have data, using 7-day window)
                    if !history.dataPoints.isEmpty {
                        RangeSelector(
                            dataPoints: history.dataPoints,
                            otherAccountsData: showOtherAccounts ? otherAccountsData : [],
                            chartDateRange: chartDateRange,
                            rangeStart: $rangeStart,
                            rangeEnd: $rangeEnd
                        )
                        .frame(height: 50)
                    }
                }

                Spacer()

                // Usage consumed stats
                HStack(spacing: 0) {
                    let (title1, value1) = usageConsumedWithLabel(targetMinutes: 30)
                    let (title2, value2) = usageConsumedWithLabel(targetMinutes: 120)
                    let (title3, value3) = usageConsumedWithLabel(targetMinutes: 1440)

                    UsageConsumedBox(title: title1, value: value1)
                    Spacer()
                    UsageConsumedBox(title: title2, value: value2)
                    Spacer()
                    UsageConsumedBox(title: title3, value: value3)
                }

                // Time until credits run out estimate
                if let estimate = timeUntilCreditsRunOut() {
                    HStack {
                        Spacer()
                        Text(estimate)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.top, 8)
                }

                // Clear data button
                HStack {
                    Spacer()
                    Button(action: {
                        showClearConfirmation = true
                    }) {
                        Text("Clear History")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 56)
        .padding(.bottom, 50)
        .frame(width: 620, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomLeading) {
            if let update = updateChecker.updateAvailable {
                Button(action: {
                    if let url = URL(string: update.releaseURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update Available: v\(update.version)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(16)
            }
        }
        .task(id: showOtherAccounts) {
            guard showOtherAccounts, comparisons == nil,
                  let loaded = try? await ChartComparisons.load(for: account.id, accounts: accounts, store: store),
                  !Task.isCancelled else { return }
            comparisons = loaded
        }
        .onAppear {
            // Initialize display name from account
            if displayName.isEmpty {
                displayName = account.displayName
            }
            if !hasInitializedRange {
                let initial = initialRangeForActiveAccount
                rangeStart = initial.start
                rangeEnd = initial.end
                hasInitializedRange = true
            }
            updateChecker.checkForUpdates()
        }
        .alert("Clear History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                // History only — the account and its credential stay, which is
                // what this alert has always promised (#106).
                store.clearAccountHistory(accountId: account.id)
                // Close this window
                if let window = ChartWindowController.windows[.account(account.id)] {
                    window.close()
                }
            }
        } message: {
            Text("This will delete all usage history for this account. New history builds up from the next poll.")
        }
    }

    var latestSessionPercent: Double? {
        history.latest?.sessionPercent
    }

    var latestWeeklyPercent: Double? {
        history.latest?.weeklyAllPercent
    }

    func usageConsumedWithLabel(targetMinutes: Int) -> (String, Double) {
        guard let oldestPoint = history.dataPoints.first else {
            return (formatDuration(minutes: targetMinutes), 0)
        }

        let now = Date()
        let dataAgeMinutes = Int(now.timeIntervalSince(oldestPoint.timestamp) / 60)

        // Use the smaller of target time or available data range
        let effectiveMinutes = min(targetMinutes, dataAgeMinutes)
        let cutoff = now.addingTimeInterval(-Double(effectiveMinutes) * 60)
        let recentPoints = history.dataPoints.filter { $0.timestamp >= cutoff }
        let consumed = recentPoints.reduce(0) { $0 + $1.usageDelta }

        // Show actual time window if less than target
        let label = effectiveMinutes < targetMinutes
            ? formatDuration(minutes: effectiveMinutes)
            : formatDuration(minutes: targetMinutes)

        return (label, consumed)
    }

    func formatDuration(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) min"
        } else if minutes < 1440 {
            let hours = minutes / 60
            return "\(hours) hr"
        } else {
            let days = minutes / 1440
            let remainingHours = (minutes % 1440) / 60
            if remainingHours > 0 {
                return "\(days)d \(remainingHours)h"
            }
            return "\(days) day"
        }
    }

    func saveNameEdit() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.updateAccountName(accountId: account.id, newName: trimmed)
            displayName = trimmed
            // Update window title
            if let window = ChartWindowController.windows[.account(account.id)] {
                window.title = "Usage History - \(trimmed)"
            }
        }
        isEditingName = false
    }

    /// Discards a projection whose exhaustion instant lands at or after the
    /// window's own reset (#221). `resetAt == nil` means the window's reset
    /// is unknown, not that it never resets, so an estimate is kept in that
    /// case rather than assumed safe or discarded — the historical
    /// (pre-#221) behavior for a window with no reset data.
    private func projectionPrecedesReset(
        minutes: Double,
        resetAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let resetAt = resetAt else { return true }
        let exhaustionInstant = now.addingTimeInterval(minutes * 60)
        return exhaustionInstant < resetAt
    }

    func timeUntilCreditsRunOut() -> String? {
        // A stale reading's rate is no longer true — the account may have
        // stopped polling for any reason (#148), so any projection built from
        // its history is equally stale. Suppress rather than show a frozen
        // extrapolation.
        if let oauthPoller = oauthPoller,
           AccountFreshness.isStale(lastUpdated: account.lastUpdated, pollInterval: oauthPoller.pollInterval) {
            return nil
        }

        var sessionEstimate = history.sessionEstimate
        var weeklyEstimate = history.weeklyEstimate

        // Discard any estimate whose projected exhaustion instant lands at or
        // after its own window's reset (#221) — an impossible projection
        // (e.g. "limited in ~2.3 days" for a session window resetting in 40
        // minutes). The reset comes from the latest polled reading, not from
        // `fullDataPoints`, which carries no reset field.
        let latestRateLimit = store.latestUsage[account.id]?.rateLimit
        if let session = sessionEstimate,
           !projectionPrecedesReset(minutes: session.minutes, resetAt: latestRateLimit?.session?.resetAt) {
            sessionEstimate = nil
        }
        if let weekly = weeklyEstimate,
           !projectionPrecedesReset(minutes: weekly.minutes, resetAt: latestRateLimit?.weekly?.resetAt) {
            weeklyEstimate = nil
        }

        // Find the shorter time
        var bestEstimate: (minutes: Double, limitType: String)? = nil

        if let session = sessionEstimate {
            if bestEstimate == nil || session.minutes < bestEstimate!.minutes {
                bestEstimate = session
            }
        }
        if let weekly = weeklyEstimate {
            if bestEstimate == nil || weekly.minutes < bestEstimate!.minutes {
                bestEstimate = weekly
            }
        }

        guard let estimate = bestEstimate else { return nil }

        let minutes = estimate.minutes
        let limitType = estimate.limitType

        if minutes <= 0 {
            return "Credits exhausted due to \(limitType)"
        } else if minutes < 60 {
            return "At current rate, access will be limited in ~\(Int(minutes)) min due to \(limitType)"
        } else if minutes < 1440 {
            let hours = minutes / 60
            return "At current rate, access will be limited in ~\(String(format: "%.1f", hours)) hr due to \(limitType)"
        } else {
            let days = minutes / 1440
            return "At current rate, access will be limited in ~\(String(format: "%.1f", days)) days due to \(limitType)"
        }
    }

    func tokenStatusColor(_ status: TokenStatus) -> Color {
        switch status {
        case .valid: return .green
        case .refreshing: return .yellow
        case .expired, .revoked, .error: return .red
        case .drifted: return .orange
        case .missing: return .gray
        }
    }

    func pollTimeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    func formatDateShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    func formatTokenCount(_ tokens: Int64) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.0fK", Double(tokens) / 1_000)
        } else {
            return "\(tokens)"
        }
    }
}

struct RangeSelector: View {
    let dataPoints: [UsageDataPoint]
    let otherAccountsData: [AccountTrace]
    let chartDateRange: (start: Date, end: Date)  // 7-day window
    @Binding var rangeStart: Double
    @Binding var rangeEnd: Double
    @Environment(\.colorScheme) var colorScheme

    private let handleWidth: CGFloat = 8
    private let minRangeWidth: Double = 0.05  // Minimum 5% of range

    var dimColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.5)
            : Color.gray.opacity(0.3)
    }

    var handleColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.8)
            : Color.gray.opacity(0.8)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let startX = CGFloat(rangeStart)
            let endX = CGFloat(rangeEnd)

            ZStack(alignment: .leading) {
                // Mini chart (full data)
                Chart {
                    // Other accounts
                    ForEach(otherAccountsData) { trace in
                        ForEach(trace.dataPoints) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Usage %", point.weeklyPercent),
                                series: .value("Account", trace.id)
                            )
                            .foregroundStyle(trace.color.opacity(0.4))
                        }
                    }

                    // Primary account
                    ForEach(dataPoints) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Usage %", point.weeklyPercent),
                            series: .value("Account", "primary")
                        )
                        .foregroundStyle(Color.blue.opacity(0.6))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: chartDateRange.start...chartDateRange.end)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)

                // Left dimmed region
                Rectangle()
                    .fill(dimColor)
                    .frame(width: max(0, width * startX))

                // Right dimmed region
                Rectangle()
                    .fill(dimColor)
                    .frame(width: max(0, width * (1 - endX)))
                    .position(x: width * endX + width * (1 - endX) / 2, y: height / 2)

                // Selection border
                RoundedRectangle(cornerRadius: 3)
                    .stroke(handleColor, lineWidth: 2)
                    .frame(width: max(handleWidth * 2, width * (endX - startX)), height: height)
                    .position(x: width * startX + width * (endX - startX) / 2, y: height / 2)

                // Left handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(handleColor)
                    .frame(width: handleWidth, height: height)
                    .position(x: width * startX + handleWidth / 2, y: height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newStart = max(0, min(Double(value.location.x / width), rangeEnd - minRangeWidth))
                                rangeStart = newStart
                            }
                    )

                // Right handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(handleColor)
                    .frame(width: handleWidth, height: height)
                    .position(x: width * endX - handleWidth / 2, y: height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newEnd = min(1, max(Double(value.location.x / width), rangeStart + minRangeWidth))
                                rangeEnd = newEnd
                            }
                    )

                // Middle drag area (for panning)
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: max(0, width * (endX - startX) - handleWidth * 2), height: height)
                    .position(x: width * startX + width * (endX - startX) / 2, y: height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let currentWidth = rangeEnd - rangeStart
                                let delta = Double(value.translation.width / width)

                                var newStart = rangeStart + delta
                                var newEnd = rangeEnd + delta

                                // Clamp to bounds
                                if newStart < 0 {
                                    newStart = 0
                                    newEnd = currentWidth
                                }
                                if newEnd > 1 {
                                    newEnd = 1
                                    newStart = 1 - currentWidth
                                }

                                rangeStart = newStart
                                rangeEnd = newEnd
                            }
                    )
            }
            .clipped()
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(colorScheme == .dark ? Color(white: 1, opacity: 0.05) : Color(white: 0, opacity: 0.03))
        )
    }
}

struct UsageConsumedBox: View {
    let title: String
    let value: Double
    @Environment(\.colorScheme) var colorScheme

    var boxBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.03)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(String(format: "+%.1f%%", value))
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(value > 0 ? .orange : .secondary)
        }
        .frame(minWidth: 100)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(boxBackground)
        .cornerRadius(8)
    }
}

// Window-controller cache: only ever touched from AppKit/SwiftUI button
// actions and view bodies, which always run on the main thread — @MainActor
// isolation matches actual usage rather than papering over it.
@MainActor
final class ChartWindowController: NSObject, NSWindowDelegate {
    private static let shared = ChartWindowController()
    enum WindowKey: Hashable {
        case account(String)
        case total(AccountProvider)
    }

    private(set) static var windows: [WindowKey: NSWindow] = [:]

    // Colors for other accounts
    nonisolated static let otherAccountColors: [Color] = [
        .orange, .green, .purple, .pink, .cyan, .yellow, .mint, .indigo
    ]

    // Colors for named per-model sub-limit overlays. A separate palette from
    // `otherAccountColors` so the two legends never read as related. Assigned
    // positionally by sorted `limit_name` (not by hashing the name into this
    // array), so a renamed model gets whatever slot its new name sorts into —
    // never silently inheriting another model's prior color out of coincidence.
    nonisolated static let namedLimitColors: [Color] = [
        .teal, .brown, .indigo, .pink, .mint, .orange, .purple, .cyan
    ]

    static func showChart(for account: Account, store: UsageStore, oauthPoller: OAuthPoller? = nil) {
        let chartView = ChartHistoryLoader(account: account, accounts: store.accounts,
                                           store: store, oauthPoller: oauthPoller)
        present(chartView, key: .account(account.id), title: "Usage History - \(account.displayName)",
                size: NSSize(width: 620, height: 610))
    }

    static func showTotal(for provider: AccountProvider, store: UsageStore) {
        let chart = ProviderHistoryChart(provider: provider, store: store)
        present(chart, key: .total(provider), title: "Usage History - \(provider.displayName) total",
                size: NSSize(width: 660, height: 520))
    }

    private static func present<Content: View>(_ content: Content, key: WindowKey, title: String, size: NSSize) {
        windows[key]?.close()
        let hostingController = NSHostingController(rootView: content)

        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(size)
        window.center()

        window.isReleasedWhenClosed = false
        window.delegate = shared
        windows[key] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = Self.windows.first(where: { $0.value === window }) else { return }
        Self.windows.removeValue(forKey: entry.key)
        window.contentViewController = nil
    }
}

#endif  // os(macOS)
