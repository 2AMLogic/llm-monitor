import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where LLM Monitor keeps its data, and the one-time move from the pre-2.0
/// `~/.claude-monitor` name.
///
/// **`dataDirectory` is the only way any code in this package finds its data
/// directory.** It is a lazily-initialized static, so the first access, from
/// any entry point (GUI, headless loop, or a one-shot CLI), runs
/// `migrateLegacyDataDirectory` exactly once before anything opens a file.
/// That ordering is what keeps a caller from creating a fresh, empty
/// `~/.llm-monitor` beside the real data. It is also why migration must not log
/// through `FileLogger`: the logger's own path comes from here.
///
/// The *move* of a real pre-2.0 `~/.claude-monitor` to `~/.llm-monitor` is
/// kept for one more major version, so a straggler 1.x host still upgrades
/// cleanly. The 2.x compatibility **symlink** at the old name is gone (#210):
/// loom-daemon reads the new path natively since v0.19.991 and every sync
/// peer answers to `llm-monitor`. Only the relative link installed by 2.x
/// is removed. A custom link may still be part of the active data path.
///
/// Portable core: no AppKit / SwiftUI / Combine / os.Logger — builds on Linux.
enum AppPaths {
    static let directoryName = ".llm-monitor"
    static let legacyDirectoryName = ".claude-monitor"

    /// `~/.llm-monitor`, migrated from `~/.claude-monitor` on first access.
    static let dataDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let outcome = migrateLegacyDataDirectory(home: home)
        if case .conflict(let message) = outcome {
            FileHandle.standardError.write(Data("llm-monitor: \(message)\n".utf8))
        }
        return (home as NSString).appendingPathComponent(directoryName)
    }()

    /// A file inside the data directory, e.g. `path("usage.db")`.
    static func path(_ name: String) -> String {
        (dataDirectory as NSString).appendingPathComponent(name)
    }

    static var databasePath: String { path("usage.db") }

    /// An environment override: `LLM_MONITOR_<name>`. Empty values count as
    /// unset. (The pre-rename `CLAUDE_MONITOR_<name>` fallback was removed
    /// with the other 2.0 compatibility shims, #210.)
    static func environment(
        _ name: String, in env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = env["LLM_MONITOR_\(name)"], !value.isEmpty { return value }
        return nil
    }

    /// Resolve a subprocess search directory beginning with `~/` against its supplied HOME.
    static func expandingHome(in path: String, environment: [String: String]) -> String? {
        guard path.hasPrefix("~/") else { return path }
        guard let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !home.isEmpty else { return nil }
        return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }

    // MARK: - Migration

    enum MigrationOutcome: Equatable {
        /// `~/.claude-monitor` was a real directory; it was moved to
        /// `~/.llm-monitor`.
        case moved
        /// `~/.claude-monitor` was a leftover compatibility symlink from a
        /// 2.x build; it was removed.
        case unlinked
        /// Nothing to move; `~/.llm-monitor` exists (created if needed).
        case clean
        /// Both names are real directories, or the legacy name is something
        /// this code did not create. Nothing was touched; `~/.llm-monitor` is
        /// used as-is.
        case conflict(String)
    }

    /// Move `<home>/.claude-monitor` to `<home>/.llm-monitor`. Idempotent, and
    /// never deletes or merges: any state it does not recognize is reported as
    /// `.conflict` and left alone. The move is kept for one more major
    /// version so a straggler 1.x host still upgrades cleanly; the 2.x
    /// compatibility symlink at the old name is no longer created, and a
    /// leftover one is removed (#210). `home` is a parameter so the self-test
    /// can drive every case in a scratch directory.
    @discardableResult
    static func migrateLegacyDataDirectory(home: String) -> MigrationOutcome {
        let fm = FileManager.default
        let newPath = (home as NSString).appendingPathComponent(directoryName)
        let legacyPath = (home as NSString).appendingPathComponent(legacyDirectoryName)

        var newIsDir: ObjCBool = false
        let newExists = fm.fileExists(atPath: newPath, isDirectory: &newIsDir)

        if let target = try? fm.destinationOfSymbolicLink(atPath: legacyPath) {
            guard target == directoryName else {
                return .conflict("preserving custom symlink \(legacyPath) -> \(target)")
            }
            if !newIsDir.boolValue {
                do {
                    try fm.createDirectory(atPath: newPath, withIntermediateDirectories: true)
                } catch {
                    return .conflict("could not create \(newPath): \(error.localizedDescription)")
                }
            }
            guard unlink(legacyPath) == 0 else {
                return .conflict("could not unlink \(legacyPath): \(String(cString: strerror(errno)))")
            }
            return .unlinked
        }

        var legacyIsDir: ObjCBool = false
        if fm.fileExists(atPath: legacyPath, isDirectory: &legacyIsDir) {
            guard legacyIsDir.boolValue else {
                return .conflict("\(legacyPath) is not a directory; left untouched")
            }
            if newExists {
                return .conflict(
                    "both \(legacyPath) and \(newPath) exist as directories; using \(newPath) and "
                    + "leaving \(legacyPath) untouched (merge or remove it, then relaunch)")
            }
            do {
                // A rename within one filesystem: processes that already hold
                // files open (e.g. a still-running older build) keep valid
                // descriptors.
                try fm.moveItem(atPath: legacyPath, toPath: newPath)
            } catch {
                return .conflict("could not move \(legacyPath) to \(newPath): \(error.localizedDescription)")
            }
            return .moved
        }

        if !newExists {
            try? fm.createDirectory(atPath: newPath, withIntermediateDirectories: true)
        }
        return .clean
    }
}
