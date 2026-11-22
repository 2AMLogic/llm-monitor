import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Directory overrides select local coding-plan files. Only the separate exact-label
/// setting grants access to a key in Loom's pool.
struct ZaiDiscovery {
    struct Seat {
        let file: ZaiKeyFile
        let fromPool: Bool
    }

    let localDirectories: [URL]
    let pool: URL?
    let labels: [String]
    let localOnly: Bool
    private let protectedPools: [URL]

    init(directory: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func url(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
        }
        let defaultPool = url(home.appendingPathComponent(".loom/api-keys/zai").path)
        if let raw = environment["LOOM_SHARED_API_KEYS_DIR"] {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let root = url(path)
            pool = path.isEmpty ? nil : url(root.lastPathComponent == "zai" ? root.path : root.appendingPathComponent("zai").path)
        } else {
            pool = defaultPool
        }
        protectedPools = [defaultPool] + (pool.map { [$0] } ?? [])
        if let directory {
            localDirectories = [url(directory)]
        } else if let dirs = environment["LLM_MONITOR_ZAI_DIRS"] ?? environment["CLAUDE_MONITOR_ZAI_DIRS"] {
            localDirectories = dirs.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.map(url)
        } else {
            localDirectories = [url(AppPaths.environment("ZAI_DIR", in: environment)
                                    ?? home.appendingPathComponent(".zai").path)]
        }
        localOnly = directory != nil
        let selected = (environment["LLM_MONITOR_ZAI_POOL_SEATS"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.validLabel)
        labels = Array(Set(selected)).sorted()
    }

    private static func validLabel(_ label: String) -> Bool {
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
        guard label.utf8.count <= 64, let first = label.first, letters.contains(first) else { return false }
        return label.allSatisfy { (letters + "_-").contains($0) }
    }

    private func insidePool(_ file: URL) -> Bool {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return protectedPools.contains { pool in
            if path == pool.path || path.hasPrefix(pool.path + "/") { return true }
            // Case-insensitive mounts may give the same directory two spellings.
            var poolStat = stat()
            guard stat(pool.path, &poolStat) == 0 else { return false }
            var ancestor = URL(fileURLWithPath: path)
            while ancestor.path != "/" && !ancestor.path.isEmpty {
                var candidate = stat()
                if stat(ancestor.path, &candidate) == 0,
                   candidate.st_dev == poolStat.st_dev, candidate.st_ino == poolStat.st_ino { return true }
                ancestor.deleteLastPathComponent()
            }
            return false
        }
    }

    /// Refuse special files and links at the point of opening the resolved path.
    static func readRegularFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              let data = try? file.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func files(read: (String) -> String? = Self.readRegularFile) -> [Seat] {
        let fm = FileManager.default
        var seats: [Seat] = []
        for dir in localDirectories where !insidePool(dir) {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names.sorted() where name.hasPrefix("coding-plan-") && name.hasSuffix(".env") {
                let label = String(name.dropFirst("coding-plan-".count).dropLast(".env".count))
                let url = dir.appendingPathComponent(name).resolvingSymlinksInPath()
                guard !label.isEmpty, !insidePool(url),
                      let body = read(url.path), let file = ZaiKeyFile.parse(body, label: label) else { continue }
                seats.append(Seat(file: file, fromPool: false))
            }
        }
        if !localOnly, !labels.isEmpty, let pool,
           let names = try? fm.contentsOfDirectory(atPath: pool.path) {
            let names = Set(names)
            var disabled = Set<String>()
            if names.contains(".disabled") {
                guard let body = read(pool.appendingPathComponent(".disabled").path) else { return deduplicated(seats) }
                disabled = Set(body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            }
            for label in labels where !disabled.contains(label) && names.contains(label + ".env") {
                let fileURL = pool.appendingPathComponent(label + ".env")
                guard fileURL.resolvingSymlinksInPath().path == fileURL.path,
                      let body = read(fileURL.path), let file = ZaiKeyFile.parse(body, label: label),
                      !file.apiKey.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else { continue }
                seats.append(Seat(file: file, fromPool: true))
            }
        }
        return deduplicated(seats)
    }

    /// Local directories precede the pool. Another copy of the identical key
    /// may supply an email but cannot change where the winning seat came from.
    private func deduplicated(_ seats: [Seat]) -> [Seat] {
        var indexes: [String: Int] = [:]
        var unique: [Seat] = []
        for seat in seats {
            if let index = indexes[seat.file.apiKey] {
                let first = unique[index]
                if first.file.email == nil, let email = seat.file.email {
                    unique[index] = Seat(file: ZaiKeyFile(label: first.file.label, email: email, apiKey: seat.file.apiKey),
                                         fromPool: first.fromPool)
                }
            } else {
                indexes[seat.file.apiKey] = unique.count
                unique.append(seat)
            }
        }
        var ids = Set<String>()
        return unique.filter { ids.insert($0.file.accountId).inserted }
    }
}
