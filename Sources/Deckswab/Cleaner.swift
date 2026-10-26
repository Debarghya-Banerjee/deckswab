import Foundation

/// A kind of regenerable data Deckswab knows how to remove.
enum Category: String, CaseIterable, Identifiable, Sendable {
    case binlogs, appUpdates, devCaches, nodeModules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .binlogs: "Local site MySQL binlogs"
        case .appUpdates: "Leftover app update downloads"
        case .devCaches: "Developer caches (npm, Homebrew…)"
        case .nodeModules: "Old node_modules"
        }
    }
}

struct Item: Identifiable, Sendable {
    enum Action: Sendable {
        case delete(URL)
        case binlogs(siteDir: URL)
    }

    let id = UUID()
    let title: String
    let detail: String
    let size: Int64
    let action: Action
}

struct Finding: Identifiable, Sendable {
    let category: Category
    let items: [Item]

    var id: Category { category }
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct CleanerSettings: Sendable {
    var nodeRoots: [URL]
    var keepPatterns: [String]
    var nodeMinAgeDays: Int
}

struct CleanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Cleaner {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser
    static let localDir = home.appending(path: "Library/Application Support/Local")

    static let devCachePaths = [
        ".npm/_cacache",
        "Library/Caches/Homebrew",
        "Library/Caches/typescript",
        "Library/Caches/Yarn",
        "Library/Caches/pip",
        "Library/Caches/composer",
    ]

    static func scan(_ category: Category, settings: CleanerSettings) -> [Item] {
        switch category {
        case .binlogs:
            binlogItems()
        case .appUpdates:
            children(of: home.appending(path: "Library/Caches"))
                .filter { $0.lastPathComponent.hasSuffix(".ShipIt") }
                .compactMap { deletable($0, detail: "Installer left behind by the app's updater") }
        case .devCaches:
            devCachePaths
                .map { home.appending(path: $0) }
                .compactMap { deletable($0, detail: "Re-downloaded when needed") }
        case .nodeModules:
            nodeModules(settings)
        }
    }

    static func clean(_ item: Item) throws {
        switch item.action {
        case .delete(let url):
            try fm.removeItem(at: url)
        case .binlogs(let siteDir):
            // Re-check: the site may have been started or stopped since the scan.
            if runningLocalSites().contains(siteDir.lastPathComponent) {
                try purgeBinlogs(socket: siteDir.appending(path: "mysql/mysqld.sock"))
            } else {
                let index = siteDir.appending(path: "mysql/data/binlog.index")
                for file in binlogFiles(in: siteDir) + [index] where fm.fileExists(atPath: file.path) {
                    try fm.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Local sites

    private static func binlogItems() -> [Item] {
        let running = runningLocalSites()
        let names = localSiteNames()

        return children(of: localDir.appending(path: "run")).compactMap { siteDir in
            let id = siteDir.lastPathComponent
            let isRunning = running.contains(id)
            // A running server keeps writing to its newest log, so only older ones can go.
            let files = binlogFiles(in: siteDir)
            let size = (isRunning ? files.dropLast() : files[...]).reduce(0) { $0 + allocatedSize($1) }
            guard 0 < size else { return nil }

            return Item(
                title: names[id] ?? id,
                detail: isRunning ? "Running: purged through MySQL" : "Stopped: log files deleted",
                size: size,
                action: .binlogs(siteDir: siteDir)
            )
        }
    }

    private static func binlogFiles(in siteDir: URL) -> [URL] {
        children(of: siteDir.appending(path: "mysql/data"))
            .filter { nil != $0.lastPathComponent.range(of: #"^binlog\.\d+$"#, options: .regularExpression) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// IDs of Local sites whose mysqld is currently running.
    private static func runningLocalSites() -> Set<String> {
        let output = (try? run("/bin/ps", ["-axo", "command"])) ?? ""
        var ids = Set<String>()
        for line in output.split(separator: "\n") where line.contains("mysqld") {
            guard let range = line.range(of: "Local/run/") else { continue }
            ids.insert(String(line[range.upperBound...].prefix { "/" != $0 }))
        }
        return ids
    }

    private static func localSiteNames() -> [String: String] {
        guard
            let data = try? Data(contentsOf: localDir.appending(path: "sites.json")),
            let sites = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return sites.compactMapValues { $0["name"] as? String }
    }

    private static func purgeBinlogs(socket: URL) throws {
        let client = children(of: localDir.appending(path: "lightning-services"))
            .filter { $0.lastPathComponent.hasPrefix("mysql-") }
            .flatMap { service in ["darwin-arm64", "darwin"].map { service.appending(path: "bin/\($0)/bin/mysql") } }
            .first { fm.isExecutableFile(atPath: $0.path) }
        guard let client else { throw CleanError(message: "MySQL client not found in Local's lightning-services") }

        try run(client.path, ["-uroot", "-proot", "-S", socket.path, "-e", "PURGE BINARY LOGS BEFORE NOW();"])
    }

    // MARK: - node_modules

    private static func nodeModules(_ settings: CleanerSettings) -> [Item] {
        let cutoff = Date().addingTimeInterval(-Double(settings.nodeMinAgeDays) * 86_400)
        var found: [URL] = []

        for root in settings.nodeRoots {
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let url = enumerator?.nextObject() as? URL {
                guard true == (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory else { continue }
                switch url.lastPathComponent {
                case "node_modules":
                    found.append(url)
                    enumerator?.skipDescendants()
                case "uploads":
                    enumerator?.skipDescendants()
                default:
                    break
                }
            }
        }

        return found
            .filter { url in !settings.keepPatterns.contains { url.path.localizedCaseInsensitiveContains($0) } }
            .filter { modified($0) < cutoff }
            .compactMap { deletable($0, detail: "Installed \(relative(modified($0)))") }
    }

    // MARK: - Helpers

    private static func deletable(_ url: URL, detail: String) -> Item? {
        let size = allocatedSize(url)
        guard 0 < size else { return nil }
        return Item(title: tilde(url), detail: detail, size: size, action: .delete(url))
    }

    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard true == values.isDirectory else { return Int64(values.totalFileAllocatedSize ?? 0) }

        var total: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func children(of url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private static func tilde(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path, with: "~")
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard 0 == process.terminationStatus else { throw CleanError(message: output) }
        return output
    }
}
