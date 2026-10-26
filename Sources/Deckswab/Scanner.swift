import AppKit

struct CleanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Finds and removes data. Everything here is synchronous and runs off the main thread.
enum Scanner {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser

    static let fullDiskAccessNote = "Deckswab needs Full Disk Access to see this."

    static func scan(_ category: Category, _ settings: ScanSettings) -> Finding {
        switch category {
        case .appCaches: Finding(category: category, items: appCaches(settings))
        case .logs: Finding(category: category, items: children(of: home.appending(path: "Library/Logs")).compactMap { item($0, title: $0.lastPathComponent) })
        case .appUpdates: Finding(category: category, items: appUpdates())
        case .iosUpdates: Finding(category: category, items: iosUpdates())
        case .leftovers: Finding(category: category, items: leftovers())
        case .trash: trash()
        case .devCaches: Finding(category: category, items: known(devCaches))
        case .xcode: Finding(category: category, items: xcode())
        case .docker: docker()
        case .homebrew: homebrew()
        case .projects: Finding(category: category, items: projects(settings))
        case .binlogs: Finding(category: category, items: binlogs())
        case .installers: Finding(category: category, items: installers())
        case .oldDownloads: Finding(category: category, items: oldDownloads(settings))
        case .largeFiles: Finding(category: category, items: largeFiles(settings))
        case .iosBackups: iosBackups()
        }
    }

    /// Removes an item and returns what was moved to the Trash, so it can be put back.
    static func clean(_ item: Item, in category: Category) throws -> [Trashed] {
        switch item.kind {
        case .binlogs:
            try cleanBinlogs(siteDir: item.url)
            return []
        case .command(let tool, let args):
            try run(tool, args, timeout: 600)
            return []
        case .file where category.movesToTrash:
            return try ([item.url] + item.extra).filter { fm.fileExists(atPath: $0.path) }.map { url in
                var result: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &result)
                return Trashed(original: url, trashed: (result as URL?) ?? url)
            }
        case .file:
            for url in [item.url] + item.extra where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            return []
        }
    }

    static func hasFullDiskAccess() -> Bool {
        nil != (try? fm.contentsOfDirectory(atPath: home.appending(path: ".Trash").path))
    }

    // MARK: - System junk

    /// Cache folders named after something other than the app that owns them.
    static let cacheOwners = [
        "Google": "com.google.Chrome",
        "Mozilla": "org.mozilla.firefox",
        "Firefox": "org.mozilla.firefox",
        "BraveSoftware": "com.brave.Browser",
        "Microsoft Edge": "com.microsoft.edgemac",
    ]

    private static func appCaches(_ settings: ScanSettings) -> [Item] {
        let prefix = "Library/Caches/"
        // Reported under Package caches and Xcode instead.
        let claimed = Set((devCaches + xcodeData).map(\.path).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })

        return children(of: home.appending(path: prefix)).compactMap { url in
            let name = url.lastPathComponent
            // macOS protects its own caches, and update leftovers have their own category.
            guard !name.hasPrefix("."), !name.hasPrefix("com.apple."), !name.hasSuffix(".ShipIt"), !claimed.contains(name), Bundle.main.bundleIdentifier != name else {
                return nil
            }
            let running = settings.runningApps.contains(cacheOwners[name] ?? name)
            return item(
                url,
                title: appName(name),
                detail: running ? "App is running, so it's left unticked" : tilde(url),
                preselected: !running
            )
        }
    }

    private static func appUpdates() -> [Item] {
        children(of: home.appending(path: "Library/Caches"))
            .filter { $0.lastPathComponent.hasSuffix(".ShipIt") }
            .compactMap { item($0, title: appName(String($0.lastPathComponent.dropLast(".ShipIt".count)))) }
    }

    private static func iosUpdates() -> [Item] {
        children(of: home.appending(path: "Library/iTunes"))
            .filter { $0.lastPathComponent.hasSuffix("Software Updates") }
            .flatMap { children(of: $0) }
            .filter { "ipsw" == $0.pathExtension.lowercased() }
            .compactMap { item($0, title: $0.lastPathComponent, detail: "Downloaded \(relative(modified($0)))", date: modified($0)) }
    }

    private static func trash() -> Finding {
        guard let urls = try? fm.contentsOfDirectory(at: home.appending(path: ".Trash"), includingPropertiesForKeys: nil) else {
            return Finding(category: .trash, items: [], note: fullDiskAccessNote)
        }
        return Finding(category: .trash, items: urls.compactMap { item($0, title: $0.lastPathComponent, detail: "In the Trash", date: added($0)) })
    }

    // MARK: - Leftovers

    /// Folders in ~/Library where apps keep data under their bundle identifier.
    /// ~/Library/Containers is left out: reading it makes macOS ask about every app.
    private static let leftoverDirs: [(path: String, suffix: String)] = [
        ("Library/Application Support", ""),
        ("Library/Preferences", ".plist"),
        ("Library/Saved Application State", ".savedState"),
        ("Library/HTTPStorages", ".binarycookies"),
        ("Library/HTTPStorages", ""),
        ("Library/WebKit", ""),
    ]

    /// Data of apps that are gone, grouped per app. To stay safe, an identifier counts only when
    /// LaunchServices doesn't know it and no installed app comes from the same vendor.
    private static func leftovers() -> [Item] {
        let vendors = installedVendors()
        var found: [String: [URL]] = [:]
        // A file matched with a suffix isn't matched again without one.
        var seen = Set<URL>()

        for (path, suffix) in leftoverDirs {
            for url in children(of: home.appending(path: path)) {
                let name = url.lastPathComponent
                guard name.hasSuffix(suffix), !seen.contains(url) else { continue }
                seen.insert(url)
                let id = String(name.dropLast(suffix.count))
                let parts = id.lowercased().split(separator: ".")
                guard
                    3 <= parts.count, parts.allSatisfy({ !$0.isEmpty }),
                    nil != id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression),
                    !parts.contains("apple"), !["group", "systemgroup"].contains(parts[0]),
                    !sharedVendors.contains(parts.prefix(2).joined(separator: ".")),
                    !vendors.contains(parts.prefix(2).joined(separator: ".")),
                    nil == NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                else { continue }
                found[id.lowercased(), default: []].append(url)
            }
        }

        return found.compactMap { id, urls in
            let size = urls.reduce(0) { $0 + allocatedSize($1) }
            guard 0 < size else { return nil }
            let places = NSOrderedSet(array: urls.map { $0.deletingLastPathComponent().lastPathComponent }).array as! [String]
            return Item(
                url: urls[0],
                title: id,
                detail: "App not installed · " + ListFormatter.localizedString(byJoining: places),
                size: size,
                preselected: false,
                date: urls.map(modified).max(),
                extra: Array(urls.dropFirst())
            )
        }
    }

    /// Frameworks that many apps embed, and Deckswab itself. Their data isn't any one app's leftovers.
    private static let sharedVendors: Set<String> = [
        "org.sparkle-project", "com.bugsnag", "com.crashlytics", "io.sentry", "com.google.keystone", "org.cups",
        "io.github.debarghya-banerjee",
    ]

    /// The first two parts of the bundle identifier of every installed app, such as "com.google".
    private static func installedVendors() -> Set<String> {
        let roots = ["/Applications", "/Applications/Utilities", home.appending(path: "Applications").path, "/System/Applications"]
        var apps = roots.flatMap { children(of: URL(fileURLWithPath: $0)) }
        // Apps one folder down, such as /Applications/Adobe Photoshop/Photoshop.app.
        apps += apps.filter { "app" != $0.pathExtension && isDirectory($0) }.flatMap(children)
        apps += NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)

        return Set(apps.filter { "app" == $0.pathExtension }.compactMap { url in
            Bundle(url: url)?.bundleIdentifier.map { $0.lowercased().split(separator: ".").prefix(2).joined(separator: ".") }
        })
    }

    // MARK: - Helpers

    /// An item for `url`, or nil when there is nothing there to free.
    static func item(_ url: URL, title: String? = nil, detail: String? = nil, preselected: Bool = true, date: Date? = nil) -> Item? {
        let size = allocatedSize(url)
        guard 0 < size else { return nil }
        return Item(url: url, title: title ?? tilde(url), detail: detail ?? tilde(url), size: size, preselected: preselected, date: date)
    }

    static func allocatedSize(_ url: URL, skipping: Set<String> = []) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard true == values.isDirectory else { return Int64(values.totalFileAllocatedSize ?? 0) }

        var total: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL {
            if !skipping.isEmpty, skipping.contains(file.path) {
                enumerator?.skipDescendants()
                continue
            }
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Walks a folder tree, skipping packages such as apps, ~/Library and any folder named in
    /// `skipping`. Hidden folders are skipped unless they match. A matching folder is returned
    /// without descending into it.
    static func walk(_ root: URL, skipping: Set<String> = ["node_modules"], where matches: (URL) -> Bool) -> [URL] {
        let library = home.appending(path: "Library").path
        var found: [URL] = []
        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if matches(url) {
                found.append(url)
                enumerator?.skipDescendants()
            } else if name.hasPrefix(".") || skipping.contains(name) || library == url.path {
                enumerator?.skipDescendants()
            }
        }
        return found
    }

    static func children(of url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    static func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    static func isDirectory(_ url: URL) -> Bool {
        true == (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func added(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate ?? modified(url)
    }

    static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    static func tilde(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path, with: "~")
    }

    /// The display name of the app with this bundle identifier, or the identifier itself.
    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Parses sizes such as "306.8MB" or "1.2 GB" as printed by brew and docker.
    static func parseSize(_ text: some StringProtocol) -> Int64 {
        guard let match = text.range(of: #"[\d.,]+\s*[kKMGTP]?i?B"#, options: .regularExpression) else { return 0 }
        let token = text[match]
        let number = Double(token.prefix { $0.isNumber || "." == $0 || "," == $0 }.replacingOccurrences(of: ",", with: "")) ?? 0
        let unit = token.last { $0.isLetter && "B" != $0 && "i" != $0 }.map { String($0).uppercased() } ?? ""
        let power = ["", "K", "M", "G", "T", "P"].firstIndex(of: unit) ?? 0
        return Int64(number * pow(1000, Double(power)))
    }

    /// Runs a tool and returns its output, throwing when it fails or takes longer than `timeout` seconds.
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        // Apps started from Finder get a bare PATH, which tools like brew and docker need.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env
        try process.run()

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        watchdog.cancel()

        guard 0 == process.terminationStatus else {
            throw CleanError(message: output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "\(tool) failed")
        }
        return output
    }

    static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { fm.isExecutableFile(atPath: $0) }
    }
}
