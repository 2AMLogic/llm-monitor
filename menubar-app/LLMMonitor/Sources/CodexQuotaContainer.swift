import Foundation

/// Codex quota readings for Loom's pooled profiles when **no Loom session
/// container is running** for them, taken in a minimal **persistent**
/// container this app keeps per profile.
///
/// `CodexProfiles` (rollout snapshots) is only as fresh as a profile's last
/// Codex turn, and `LoomAccountsCheck` (the live check) measures only inside a
/// running Loom session container. A host with neither — operator-directed
/// Loom with no daemon, or a daemon whose reconciler could not bring the
/// sessions back after a reboot — therefore reported nothing at all until
/// someone ran Codex again. This closes that gap with one long-lived
/// container per profile:
///
/// ```
/// docker run -d --init --restart unless-stopped \
///   --name llm-monitor-codex-quota-<profile> \
///   -v <profile home>:/codex-home -e CODEX_HOME=/codex-home … <image> sleep infinity
/// ```
///
/// which idles (it runs nothing but `sleep`) and survives app restarts and
/// reboots. Each reading is one
/// `docker exec -i <name> codex -s read-only -a never app-server`, spoken to
/// by the existing `CodexAppServerClient` handshake (`ContainerLaunch`), so
/// the wire handling is the one implementation. `reconcile` is the single
/// place a container is created, started, replaced or removed: it runs once
/// per cycle from one `docker ps -a` read.
///
/// **What this changes about ownership, deliberately.** Until now this app
/// never ran `codex` against a profile home, because Loom's session container
/// was the single user of that home's login. This is a second user, bounded
/// by three rules:
///
/// 1. **Never beside a running Loom session.** A profile whose
///    `loom-codex-session-<profile>` container is running is not probed;
///    Loom's live check covers it. Its quota container stays up but idle —
///    `sleep` opens nothing in the home — so only an `exec` counts as use.
/// 2. **The whole home is mounted, never `auth.json` alone.** Codex replaces
///    `auth.json` by rename and serializes writers on `auth.lock` in the same
///    directory (codex-rs `login/src/auth/storage.rs`). A single-file bind
///    mount cannot be renamed over, so a token refresh inside the container
///    would rotate the refresh token at OpenAI and then fail to save it.
///    Mounting the directory keeps a refresh durable and lock-serialized
///    against any other `codex` using that home.
/// 3. **No credential is read, copied or stored by this app.** Only `codex`
///    inside the container opens `auth.json`; this app sees rate-limit
///    numbers and the plan name.
///
/// Codex does write into the mounted home while it runs (its SQLite state and
/// `models_cache.json`), exactly as a session there would.
///
/// The three guards in the `CodexProfiles` entry of CLAUDE.md are unchanged:
/// `pollOpenAI` still returns to `pollCodexSnapshot` before either ladder
/// rung, `registerCodexHome` still refuses a profile path, and `codex list`
/// still prints the snapshot. This is the fourth `Process()` user on the poll
/// path and is reached only for a snapshot-mode home.
///
/// Every failure — no container runtime, runtime not answering, image not
/// built yet, a probe that errors — leaves the other two sources in charge
/// and never marks an account unhealthy. A profile *name* is logged, never a
/// home path.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
enum CodexQuotaContainer {
    // MARK: - Configuration

    /// `LLM_MONITOR_CODEX_QUOTA_CONTAINER=0` (or `false`/`off`/`no`) turns the
    /// whole feature off. Anything else, including unset, leaves it on.
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = AppPaths.environment("CODEX_QUOTA_CONTAINER", in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return true }
        return !["0", "false", "off", "no"].contains(raw)
    }

    /// The Codex release baked into the built-in image. Bump it here; the tag
    /// carries it, so a new version builds a new image instead of silently
    /// reusing the old one.
    static let codexVersion = "0.171.0"

    /// The image this app builds for itself when none is configured.
    static var builtInImage: String { "llm-monitor-codex-quota:\(codexVersion)" }

    /// The image to run and whether this app is responsible for building it.
    /// `LLM_MONITOR_CODEX_QUOTA_IMAGE` names any image with `codex` on its
    /// `PATH`; an override is run as given and never built here.
    static func image(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (name: String, isBuiltIn: Bool) {
        if let override = AppPaths.environment("CODEX_QUOTA_IMAGE", in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return (override, false)
        }
        return (builtInImage, true)
    }

    /// The built-in image: Alpine, CA certificates, and the static `codex`
    /// release binary for the build host's architecture. Nothing else — no
    /// shell tooling, no workspace, no git. Fed to `docker build -` on stdin,
    /// so there is no build context and nothing on disk to keep in sync.
    static let dockerfile = """
    FROM alpine:3.20
    ARG CODEX_VERSION
    RUN set -eu; apk add --no-cache ca-certificates; \\
        arch="$(uname -m)"; \\
        case "$arch" in aarch64|x86_64) ;; *) echo "unsupported architecture: $arch" >&2; exit 1 ;; esac; \\
        wget -qO- "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-${arch}-unknown-linux-musl.tar.gz" \\
          | tar -xz -C /usr/local/bin; \\
        mv "/usr/local/bin/codex-${arch}-unknown-linux-musl" /usr/local/bin/codex; \\
        chmod 0755 /usr/local/bin/codex
    ENTRYPOINT []

    """

    // MARK: - Runtime resolution

    /// Explicit override, and the seam `selftest` points at a stub. Same
    /// reason as `LLM_MONITOR_CODEX_BIN`: a Finder-launched bundle's `PATH`
    /// does not include where Docker installs its CLI.
    static let overrideEnvKey = "LLM_MONITOR_DOCKER_BIN"

    static let fallbackDirectories = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
        "~/.docker/bin",
        "/usr/bin",
    ]

    /// First executable `docker` among the override, `PATH`, then
    /// `fallbackDirectories`. Nil is the ordinary state of a host without a
    /// container runtime, never an error.
    static func resolveDocker(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = AppPaths.environment("DOCKER_BIN", in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirs + fallbackDirectories {
            guard !directory.isEmpty else { continue }
            var expanded = directory
            if expanded.hasPrefix("~/") {
                guard let home = home, !home.isEmpty else { continue }
                expanded = (home as NSString).appendingPathComponent(String(expanded.dropFirst(2)))
            }
            let candidate = (expanded as NSString).appendingPathComponent("docker")
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Names and arguments

    /// Where the profile is mounted inside the container.
    static let containerHome = "/codex-home"

    /// The name of Loom's own session container for a profile — loom-daemon's
    /// `loom-codex-session-<name>` convention (what each profile's
    /// `.session-managed.json` records).
    static func loomSessionContainerName(profile: String) -> String {
        "loom-codex-session-\(profile)"
    }

    /// Every container this app owns starts with this, which is how
    /// `reconcile` recognises one whose profile is gone.
    static let containerNamePrefix = "llm-monitor-codex-quota-"

    /// Label recording which host directory a container mounts, so a profile
    /// root that moved is noticed and the container replaced.
    static let homeLabel = "llm-monitor.codex-home"

    /// This app's container for a profile, or nil for a profile name with no
    /// characters a container name may carry. Fixed per profile: one account,
    /// one container.
    static func containerName(profile: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let cleaned = String(profile.map { allowed.contains($0) ? $0 : "-" })
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return containerNamePrefix + cleaned
    }

    /// The argv that creates a profile's persistent container, spelled once
    /// so the self-test and the poll path cannot disagree.
    ///
    /// The container gets the profile and nothing else: no workspace, no
    /// other credential, a read-only root with a private `/tmp`, every
    /// capability dropped. It runs as the invoking user so anything Codex
    /// writes into the home stays owned by that user on a Linux host.
    /// `--restart unless-stopped` brings it back after a reboot or a runtime
    /// restart; `--init` makes the idle `sleep` stop promptly.
    static func createArguments(
        name: String, home: String, image: String, uid: UInt32, gid: UInt32
    ) -> [String] {
        [
            "run", "-d", "--init",
            "--restart", "unless-stopped",
            "--name", name,
            "--label", "\(homeLabel)=\(home)",
            "--user", "\(uid):\(gid)",
            "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges",
            "--read-only", "--tmpfs", "/tmp",
            "-e", "HOME=/tmp",
            "-e", "CODEX_HOME=\(containerHome)",
            "-v", "\(home):\(containerHome)",
            image, "sleep", "infinity",
        ]
    }

    /// Everything between the runtime binary and `codex …` for one reading.
    static func execArguments(name: String) -> [String] { ["exec", "-i", name] }

    // MARK: - Runtime queries

    /// One row of `docker ps -a`.
    struct ContainerInfo: Sendable, Equatable {
        let name: String
        /// `running`, `exited`, `created`, `paused`, `restarting`, `dead`.
        let state: String
        let image: String
        /// The `homeLabel` value; empty on a container that is not ours.
        let home: String
        var isRunning: Bool { state == "running" }
    }

    static let listArguments = [
        "ps", "-a", "--format",
        "{{.Names}}\t{{.State}}\t{{.Image}}\t{{.Label \"\(homeLabel)\"}}",
    ]

    /// Parse `listArguments` output. Pure, for the self-test.
    static func parseContainerList(_ text: String) -> [String: ContainerInfo] {
        var out: [String: ContainerInfo] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { continue }
            out[fields[0]] = ContainerInfo(
                name: fields[0], state: fields[1], image: fields[2],
                home: fields.count > 3 ? fields[3] : "")
        }
        return out
    }

    /// Every container, running or not, by name — or nil when the runtime did
    /// not answer (not installed, daemon down, timed out), which the caller
    /// must read as "cannot tell whether a Loom session is running", so
    /// nothing is created or probed.
    static func listContainers(docker: String, timeout: TimeInterval = 15) async -> [String: ContainerInfo]? {
        guard let result = await SubprocessIO.runCapturing(
            executable: docker, arguments: listArguments, timeout: timeout
        ), result.succeeded else { return nil }
        return parseContainerList(String(decoding: result.stdout, as: UTF8.self))
    }

    static func imageExists(docker: String, image: String, timeout: TimeInterval = 15) async -> Bool {
        let result = await SubprocessIO.runCapturing(
            executable: docker, arguments: ["image", "inspect", "--format", "{{.Id}}", image],
            timeout: timeout
        )
        return result?.succeeded ?? false
    }

    /// Build the built-in image. Returns nil on success, else a short reason
    /// (the tail of the builder's stderr, home paths collapsed).
    static func buildImage(docker: String, timeout: TimeInterval = 600) async -> String? {
        guard let result = await SubprocessIO.runCapturing(
            executable: docker,
            arguments: ["build", "-q", "--build-arg", "CODEX_VERSION=\(codexVersion)",
                        "-t", builtInImage, "-"],
            input: Data(dockerfile.utf8), timeout: timeout
        ) else { return "could not start the container runtime" }
        if result.succeeded { return nil }
        guard result.status != nil else { return "timed out" }
        return failureText(result)
    }

    private static func failureText(_ result: SubprocessIO.Captured) -> String {
        guard let status = result.status else { return "timed out" }
        let tail = String(decoding: result.stderr.suffix(400), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return redactHomePaths(inText: tail.isEmpty ? "exit \(status)" : tail)
    }

    // MARK: - Reconciling the persistent containers

    /// What one profile's container needs to match what is wanted.
    enum Action: Sendable, Equatable {
        /// Running, right image, right mount.
        case none
        /// Present and correct but not running.
        case start
        /// Absent.
        case create
        /// Present with the wrong image or mount (a Codex version bump, a
        /// moved profile root) — removed and created again.
        case replace
    }

    /// Pure decision for one profile, for the self-test.
    static func action(existing: ContainerInfo?, home: String, image: String) -> Action {
        guard let existing = existing else { return .create }
        guard existing.image == image, existing.home == home else { return .replace }
        return existing.isRunning ? .none : .start
    }

    /// Containers of ours whose profile is no longer wanted. Pure.
    static func orphans(in containers: [String: ContainerInfo], wantedNames: Set<String>) -> [String] {
        containers.keys.filter { $0.hasPrefix(containerNamePrefix) && !wantedNames.contains($0) }.sorted()
    }

    /// Bring one profile's container to the wanted state. Nil on success,
    /// else a short reason.
    static func ensureContainer(
        docker: String, name: String, home: String, image: String, existing: ContainerInfo?
    ) async -> String? {
        var needed = action(existing: existing, home: home, image: image)
        if needed == .none { return nil }
        if needed == .start {
            if let started = await SubprocessIO.runCapturing(
                executable: docker, arguments: ["start", name], timeout: 30), started.succeeded {
                return nil
            }
            needed = .replace  // a container that will not start is replaced
        }
        if needed == .replace {
            _ = await SubprocessIO.runCapturing(executable: docker, arguments: ["rm", "-f", name], timeout: 30)
        }
        guard let created = await SubprocessIO.runCapturing(
            executable: docker,
            arguments: createArguments(name: name, home: home, image: image, uid: getuid(), gid: getgid()),
            timeout: 120
        ) else { return "could not start the container runtime" }
        return created.succeeded ? nil : failureText(created)
    }

    /// One `reconcile` pass: every wanted profile has a running container,
    /// and containers of ours for profiles that are gone are removed.
    /// Returns the homes whose container is up, and a reason per home that
    /// could not be brought up.
    static func reconcile(
        docker: String, image: String, homes: [String], containers: [String: ContainerInfo]
    ) async -> (ready: [String], failures: [String: String]) {
        var ready: [String] = []
        var failures: [String: String] = [:]
        var wanted = Set<String>()
        for home in homes {
            guard let name = containerName(profile: (home as NSString).lastPathComponent) else { continue }
            wanted.insert(name)
            if let failure = await ensureContainer(
                docker: docker, name: name, home: home, image: image, existing: containers[name]) {
                failures[home] = failure
            } else {
                ready.append(home)
            }
        }
        for orphan in orphans(in: containers, wantedNames: wanted) {
            _ = await SubprocessIO.runCapturing(executable: docker, arguments: ["rm", "-f", orphan], timeout: 30)
        }
        return (ready, failures)
    }

    // MARK: - Probing

    /// One profile's measurement.
    struct Reading: Sendable {
        /// When the probe ran — the timestamp any row written from it carries.
        let observedAt: Date
        let rateLimit: RateLimitSnapshot
        let plan: String?
    }

    enum ProbeResult: Sendable {
        case reading(Reading)
        /// Why nothing was measured; already free of home paths.
        case failed(String)
    }

    /// Which homes get a container at all: nameable and logged in. Pure.
    static func managedHomes(
        _ homes: [String],
        isLoggedIn: (String) -> Bool = { CodexAuth.accountId(inHome: $0) != nil }
    ) -> [String] {
        homes.filter { containerName(profile: ($0 as NSString).lastPathComponent) != nil && isLoggedIn($0) }
    }

    /// Which homes to probe this cycle: logged in, nameable, and with no Loom
    /// session container running. Pure, so the self-test pins the skip rules.
    static func eligibleHomes(
        _ homes: [String], runningContainers: Set<String>,
        isLoggedIn: (String) -> Bool = { CodexAuth.accountId(inHome: $0) != nil }
    ) -> [String] {
        homes.filter { home in
            let profile = (home as NSString).lastPathComponent
            guard containerName(profile: profile) != nil else { return false }
            guard !runningContainers.contains(loomSessionContainerName(profile: profile)) else { return false }
            return isLoggedIn(home)
        }
    }

    /// Read one profile's rate limits by `exec` in its persistent container.
    ///
    /// A probe that **timed out** removes the container: killing the
    /// runtime's CLI at a deadline does not stop the `codex` it started
    /// inside, and the next `reconcile` creates a clean one. Any other
    /// failure leaves the container alone — recreating it would not help.
    static func probe(
        docker: String, home: String,
        timeouts: CodexAppServerClient.Timeouts = CodexAppServerClient.Timeouts()
    ) async -> ProbeResult {
        let profile = (home as NSString).lastPathComponent
        guard let name = containerName(profile: profile) else {
            return .failed("profile name cannot name a container")
        }
        let client = CodexAppServerClient(
            codexHome: home, timeouts: timeouts,
            containerLaunch: .init(executable: docker, arguments: execArguments(name: name))
        )
        do {
            let usage = try await client.fetchUsage()
            guard !usage.rateLimit.isEmpty else { return .failed("Codex reported no rate-limit window") }
            return .reading(Reading(observedAt: Date(), rateLimit: usage.rateLimit, plan: usage.plan))
        } catch {
            if case CodexAppServerError.timedOut = error {
                _ = await SubprocessIO.runCapturing(executable: docker, arguments: ["rm", "-f", name], timeout: 30)
            }
            return .failed(redactHomePaths(inText: error.localizedDescription))
        }
    }

    /// Probe several homes, at most `concurrency` at a time, keyed by home.
    static func probeAll(
        docker: String, homes: [String], concurrency: Int = 4
    ) async -> [String: ProbeResult] {
        var results: [String: ProbeResult] = [:]
        var index = 0
        while index < homes.count {
            let batch = Array(homes[index..<min(index + max(1, concurrency), homes.count)])
            index += batch.count
            await withTaskGroup(of: (String, ProbeResult).self) { group in
                for home in batch {
                    group.addTask { (home, await probe(docker: docker, home: home)) }
                }
                for await (home, result) in group { results[home] = result }
            }
        }
        return results
    }
}
