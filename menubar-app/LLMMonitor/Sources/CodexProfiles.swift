import Foundation

/// Read-only visibility into Loom's pooled Codex profiles
/// (`~/.loom/codex-profiles/<name>/`, or `$LOOM_CODEX_PROFILE_ROOT`).
///
/// ### Why snapshots, never a live call
///
/// Loom's session containers **own** these homes. OpenAI rotates the refresh
/// token on every use, so exactly one process may ever refresh a given
/// `CODEX_HOME`, and for a session-managed profile that process is the
/// container. Spawning `codex app-server` against one of these homes (the
/// normal `pollOpenAI` ladder) could refresh behind the container's back and
/// break that account's auth chain. So a profile is registered in
/// **snapshot mode** (`accounts.codex_home_mode = 'snapshot'`): it is read
/// only from the `rate_limits` object Codex itself writes into the profile's
/// `sessions/**/rollout-*.jsonl` during normal use. No credential is read, no
/// process is started, and nothing is written into the profile.
///
/// The price is freshness: a reading is only as current as the account's
/// last Codex turn. The reading is timestamped with **when Codex recorded
/// it**, never when we read it, so the cause-independent staleness backstop
/// (`AccountFreshness`) shows an idle account as stale rather than current.
///
/// ### Wire shape (codex-cli 0.156, verified 2026-09-25)
///
/// ```json
/// {"timestamp":"2026-09-23T16:56:22.026Z", ... "rate_limits":{"limit_id":"codex",
///   "primary":{"used_percent":43.0,"window_minutes":10080,"resets_at":1790713159},
///   "secondary":null,"plan_type":"pro", ...}}
/// ```
///
/// - **`primary` is the weekly window here** (`window_minutes: 10080`), with
///   `secondary: null`. As everywhere in this app, the kind is derived from
///   the duration, never from the slot (see `RateLimitWindow`).
/// - `resets_at` is an **integer epoch** on this version. An RFC 3339 string
///   and a relative `resets_in_seconds` are also accepted (older vintages,
///   the same set loom-daemon's `codex_check.rs` reads).
/// - A window whose reset instant has already passed describes a window that
///   has since rolled over. It is dropped (unknown), never carried forward.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
enum CodexProfiles {
    /// `accounts.codex_home_mode` value for a home read only from snapshots.
    static let snapshotMode = "snapshot"
    /// Stable id prefix for a profile row that has no `tokens.account_id` to
    /// key on (a profile that was never logged in).
    static let accountIdPrefix = "codex-profile:"

    /// `$LOOM_CODEX_PROFILE_ROOT` (an explicitly empty value disables it,
    /// matching loom-daemon's `codex_profile_root()`), else
    /// `~/.loom/codex-profiles`.
    static func root(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let value = environment["LOOM_CODEX_PROFILE_ROOT"] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            return (trimmed as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".loom/codex-profiles").path
    }

    /// Identity and type as reported by a single directory listing.
    struct RootEntry: Hashable {
        enum Kind: Hashable { case directory, other, needsLookup }
        let name: String
        let home: String
        let inode: ino_t
        let kind: Kind
    }

    struct RootListing {
        let entries: [RootEntry]
        let modificationTime: timespec?
    }

    /// The visible entries of `root` in name order, or nil when the root cannot
    /// be listed (disabled, missing, unreadable). The type comes from the
    /// listing (`d_type`), so a regular file costs no metadata lookup; only a
    /// symlink or a filesystem that reports no type needs one.
    static func listRoot(_ root: String?) -> RootListing? {
        guard let root = root, let stream = opendir(root) else { return nil }
        defer { closedir(stream) }
        // Sample the open root before reading entries. A concurrent replacement
        // during enumeration remains visible as a change on the next tick.
        var metadata = stat()
        let hasMetadata = fstat(dirfd(stream), &metadata) == 0
        #if os(macOS)
        let modificationTime = hasMetadata ? metadata.st_mtimespec : nil
        #else
        let modificationTime = hasMetadata ? metadata.st_mtim : nil
        #endif
        var entries: [RootEntry] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard !name.hasPrefix(".") else { continue }  // also drops "." and ".."
            let kind: RootEntry.Kind
            switch Int32(entry.pointee.d_type) {
            case Int32(DT_DIR): kind = .directory
            case Int32(DT_UNKNOWN), Int32(DT_LNK): kind = .needsLookup
            default: kind = .other
            }
            entries.append(RootEntry(name: name, home: (root as NSString).appendingPathComponent(name),
                                     inode: entry.pointee.d_ino, kind: kind))
        }
        return RootListing(entries: entries.sorted { $0.name < $1.name }, modificationTime: modificationTime)
    }

    /// Resolve an untyped entry without caching a symlink's mutable target
    /// or a transient lookup failure as a regular file.
    static func lookupKind(_ path: String) -> RootEntry.Kind {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return .needsLookup }
        switch metadata.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK):
            guard stat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else { return .needsLookup }
            return .directory
        default: return .other
        }
    }

    // MARK: - Snapshot

    struct Snapshot {
        /// When Codex recorded the reading (the rollout line's own timestamp,
        /// else the file's mtime).
        let observedAt: Date
        /// Every window still live at read time, filed by duration.
        let rateLimit: RateLimitSnapshot
        let plan: String?
        /// Windows present in the reading but already rolled over.
        let expiredWindows: Int
    }

    /// Newest-first rollout files examined per profile. The newest session
    /// often carries no `rate_limits` line at all (a session that ended before
    /// its first model turn), so stopping at one file would blind a busy
    /// profile; the cap keeps a 600-session profile from costing a full scan.
    static let maxFilesExamined = 8
    /// Bytes read from the end of each file. The winning line is the *last*
    /// one, so the tail is all that matters.
    static let maxTailBytes = 512 * 1024
    private static let maxWalkEntries = 20_000

    /// The freshest usable reading in a profile, or nil when it has none.
    static func latestSnapshot(home: String, now: Date = Date()) -> Snapshot? {
        for (path, mtime) in rolloutFilesNewestFirst(home: home).prefix(maxFilesExamined) {
            guard let text = readTail(path) else { continue }
            if let snapshot = extractSnapshot(text: text, fallbackObservedAt: mtime, now: now) {
                return snapshot
            }
        }
        return nil
    }

    /// The **last** usable `rate_limits` reading in a rollout log's text.
    /// Split out from the file walk so the self-test can drive it offline.
    static func extractSnapshot(text: String, fallbackObservedAt: Date, now: Date = Date()) -> Snapshot? {
        for rawLine in text.split(whereSeparator: \.isNewline).reversed() {
            guard rawLine.contains("rate_limits"),
                  let object = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)),
                  let limits = findRateLimits(object) else { continue }
            let observedAt = (object as? [String: Any]).flatMap { UsageRecord.parseISO($0["timestamp"] as? String) }
                ?? fallbackObservedAt
            let parsed = ["primary", "secondary"].compactMap { parseWindow(limits[$0], observedAt: observedAt) }
            guard !parsed.isEmpty else { continue }
            let live = parsed.filter { $0.resetAt.map { $0 > now } ?? true }
            let plan = (limits["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Snapshot(
                observedAt: observedAt,
                rateLimit: RateLimitSnapshot(windows: live),
                plan: plan,
                expiredWindows: parsed.count - live.count
            )
        }
        return nil
    }

    /// The first `rate_limits` object at any depth. A search rather than a
    /// fixed path, because the CLI has carried it at more than one nesting
    /// depth across versions.
    private static func findRateLimits(_ value: Any) -> [String: Any]? {
        if let map = value as? [String: Any] {
            if let limits = map["rate_limits"] as? [String: Any] { return limits }
            for child in map.values { if let found = findRateLimits(child) { return found } }
        } else if let items = value as? [Any] {
            for child in items { if let found = findRateLimits(child) { return found } }
        }
        return nil
    }

    private static func parseWindow(_ value: Any?, observedAt: Date) -> RateLimitWindow? {
        guard let map = value as? [String: Any],
              let used = (map["used_percent"] as? NSNumber)?.doubleValue,
              used.isFinite, used >= 0 else { return nil }
        let duration = (map["window_minutes"] as? NSNumber).map { $0.doubleValue * 60 }
        var reset: Date?
        if let epoch = map["resets_at"] as? NSNumber {
            reset = Date(timeIntervalSince1970: epoch.doubleValue)
        } else if let iso = map["resets_at"] as? String {
            reset = UsageRecord.parseISO(iso)
        } else if let seconds = map["resets_in_seconds"] as? NSNumber {
            reset = observedAt.addingTimeInterval(seconds.doubleValue)
        }
        let percent = min(100, used)
        return RateLimitWindow(
            kind: RateLimitWindow.kind(forDuration: duration),
            usedPercent: percent,
            durationSeconds: duration,
            resetAt: reset,
            status: percent >= 100 ? "rejected" : "allowed"
        )
    }

    private static func rolloutFilesNewestFirst(home: String) -> [(String, Date)] {
        let sessions = (home as NSString).appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sessions),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(String, Date)] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maxWalkEntries { break }
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append((url.path, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }
    }

    /// The last `maxTailBytes` of a file, minus any leading partial line.
    private static func readTail(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard start > 0 else { return text }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map(String.init) ?? ""
    }
}
