import Foundation

extension Scanner {
    // MARK: - Package caches

    static let devCaches: [(path: String, title: String)] = [
        (".npm/_cacache", "npm"),
        ("Library/pnpm/store", "pnpm"),
        ("Library/Caches/Yarn", "Yarn"),
        (".bun/install/cache", "Bun"),
        ("Library/Caches/Homebrew", "Homebrew downloads"),
        ("Library/Caches/pip", "pip"),
        ("Library/Caches/pypoetry", "Poetry"),
        ("Library/Caches/uv", "uv"),
        ("Library/Caches/CocoaPods", "CocoaPods"),
        ("Library/Caches/go-build", "Go build cache"),
        ("Library/Caches/deno", "Deno"),
        (".gradle/caches", "Gradle"),
        (".m2/repository", "Maven"),
        (".cargo/registry/cache", "Cargo"),
        ("Library/Caches/composer", "Composer"),
        (".composer/cache", "Composer"),
        (".cache/wp-cli", "WP-CLI"),
        ("Library/Caches/typescript", "TypeScript"),
        ("Library/Caches/ms-playwright", "Playwright browsers"),
        (".cache/puppeteer", "Puppeteer browsers"),
        ("Library/Caches/node-gyp", "node-gyp"),
    ]

    static func known(_ list: [(path: String, title: String)]) -> [Item] {
        list.compactMap { item(home.appending(path: $0.path), title: $0.title) }
    }

    // MARK: - Xcode

    static let xcodeData: [(path: String, title: String)] = [
        ("Library/Developer/Xcode/DerivedData", "Build data (DerivedData)"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "iOS device support"),
        ("Library/Developer/Xcode/watchOS DeviceSupport", "watchOS device support"),
        ("Library/Developer/Xcode/UserData/Previews", "SwiftUI previews"),
        ("Library/Developer/CoreSimulator/Caches", "Simulator caches"),
        ("Library/Caches/com.apple.dt.Xcode", "Xcode cache"),
    ]

    static func xcode() -> [Item] {
        var items = known(xcodeData)

        // Archives hold the debug symbols of shipped builds, so they're never ticked.
        let archives = home.appending(path: "Library/Developer/Xcode/Archives")
        if let archive = item(archives, title: "Archives", detail: "Needed to symbolicate crashes of shipped builds", preselected: false) {
            items.append(archive)
        }

        // Simulators whose runtime is gone. Needs Xcode; the Command Line Tools have no simctl.
        if let output = try? run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
           let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
           let runtimes = json["devices"] as? [String: [[String: Any]]] {
            let devices = runtimes.values.flatMap { $0 }.compactMap { $0["dataPath"] as? String }
            let size = devices.reduce(0) { $0 + allocatedSize(URL(fileURLWithPath: $1).deletingLastPathComponent()) }
            if 0 < size {
                items.append(Item(
                    url: URL(fileURLWithPath: "/deckswab/simctl-unavailable"),
                    title: "Unavailable simulators",
                    detail: "\(devices.count) simulators whose iOS version is no longer installed",
                    size: size,
                    kind: .command("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
                ))
            }
        }
        return items
    }

    // MARK: - Docker

    static func docker() -> Finding {
        guard let docker = firstExecutable([
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            home.appending(path: ".orbstack/bin/docker").path,
        ]) else {
            return Finding(category: .docker, items: [])
        }
        guard let output = try? run(docker, ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"], timeout: 30) else {
            return Finding(category: .docker, items: [], note: "Start Docker to see what it can free.")
        }

        // Volumes hold data, so they're left alone.
        let actions: [String: (title: String, detail: String, args: [String], preselected: Bool)] = [
            "Build Cache": ("Build cache", "Rebuilt on the next docker build", ["builder", "prune", "--all", "--force"], true),
            "Images": ("Unused images", "Images no container uses. Pulled again when needed", ["image", "prune", "--all", "--force"], false),
            "Containers": ("Stopped containers", "Their files are lost when they're removed", ["container", "prune", "--force"], false),
        ]

        let items = output.split(separator: "\n").compactMap { line -> Item? in
            let parts = line.split(separator: "\t")
            guard 2 == parts.count, let action = actions[String(parts[0])] else { return nil }
            let size = parseSize(parts[1])
            guard 0 < size else { return nil }
            return Item(
                url: URL(fileURLWithPath: "/deckswab/docker/\(parts[0])"),
                title: action.title,
                detail: action.detail,
                size: size,
                preselected: action.preselected,
                kind: .command(docker, action.args)
            )
        }
        return Finding(category: .docker, items: items)
    }

    // MARK: - Homebrew

    static func homebrew() -> Finding {
        guard let brew = firstExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]),
              let output = try? run(brew, ["cleanup", "--dry-run"], timeout: 120)
        else { return Finding(category: .homebrew, items: []) }

        // Downloads are counted under Package caches.
        let lines = output.split(separator: "\n").filter { $0.hasPrefix("Would remove: ") && !$0.contains("/Library/Caches/Homebrew") }
        let size = lines.reduce(0) { total, line in
            total + parseSize(line.split(separator: ",").last ?? "")
        }
        guard 0 < size else { return Finding(category: .homebrew, items: []) }

        return Finding(category: .homebrew, items: [Item(
            url: URL(fileURLWithPath: "/deckswab/brew-cleanup"),
            title: "Outdated formulae and casks",
            detail: "\(lines.count) old versions · runs brew cleanup",
            size: size,
            kind: .command(brew, ["cleanup"])
        )])
    }

    // MARK: - Project dependencies

    /// Folders that a package manager or build tool recreates, keyed by name. Each is
    /// recognised only next to the file that proves what made it.
    static let artifacts: [String: (marker: String, label: String)] = [
        "node_modules": ("package.json", "node_modules"),
        ".venv": ("pyvenv.cfg", "Python virtualenv"),
        "venv": ("pyvenv.cfg", "Python virtualenv"),
        "target": ("../Cargo.toml", "Rust build output"),
        ".next": ("../package.json", "Next.js build cache"),
        ".nuxt": ("../package.json", "Nuxt build cache"),
        ".turbo": ("../package.json", "Turborepo cache"),
        ".parcel-cache": ("../package.json", "Parcel cache"),
        ".angular": ("../package.json", "Angular cache"),
    ]

    static func projects(_ settings: ScanSettings) -> [Item] {
        let cutoff = Date().addingTimeInterval(-Double(settings.nodeMinAgeDays) * 86_400)

        return settings.nodeRoots
            .flatMap { root in
                // WordPress uploads hold thousands of files and never a project.
                walk(root, skipping: ["uploads", "Library"]) { artifactLabel($0) != nil }
            }
            .filter { url in !settings.keepPatterns.contains { url.path.localizedCaseInsensitiveContains($0) } }
            .filter { modified($0) < cutoff }
            .compactMap { url in
                let date = modified(url)
                return item(
                    url,
                    title: tilde(url.deletingLastPathComponent()),
                    detail: "\(artifactLabel(url) ?? url.lastPathComponent) · last changed \(relative(date))",
                    date: date
                )
            }
    }

    private static func artifactLabel(_ url: URL) -> String? {
        guard let artifact = artifacts[url.lastPathComponent] else { return nil }
        // node_modules sometimes sits without a package.json, as in hoisted monorepos.
        if "node_modules" == url.lastPathComponent { return isDirectory(url) ? artifact.label : nil }
        let marker = artifact.marker.hasPrefix("../")
            ? url.deletingLastPathComponent().appending(path: String(artifact.marker.dropFirst(3)))
            : url.appending(path: artifact.marker)
        return exists(marker) ? artifact.label : nil
    }

    // MARK: - Local sites

    static let localDir = home.appending(path: "Library/Application Support/Local")

    static func binlogs() -> [Item] {
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
                url: siteDir,
                title: names[id] ?? id,
                detail: isRunning ? "Running: purged through MySQL" : "Stopped: log files deleted",
                size: size,
                kind: .binlogs
            )
        }
    }

    static func cleanBinlogs(siteDir: URL) throws {
        // Re-check: the site may have been started or stopped since the scan.
        if runningLocalSites().contains(siteDir.lastPathComponent) {
            try purgeBinlogs(socket: siteDir.appending(path: "mysql/mysqld.sock"))
            return
        }
        let index = siteDir.appending(path: "mysql/data/binlog.index")
        for file in binlogFiles(in: siteDir) + [index] where fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
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
}
