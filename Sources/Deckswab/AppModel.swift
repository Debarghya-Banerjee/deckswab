import AppKit
import ServiceManagement
import UserNotifications

enum Route: Hashable {
    case overview
    case lens
    case category(Category)
}

enum Prefs {
    static let defaults = UserDefaults.standard
    static let defaultRoots = "~/Documents/Projects\n~/Developer\n~/Projects\n~/Sites\n~/Local Sites\n~/LocalDev"

    static func register() {
        defaults.register(defaults: [
            "thresholdGB": 20,
            "autoClean": false,
            "autoCleanNodeModules": false,
            "nodeMinAgeDays": 14,
            "nodeRoots": defaultRoots,
            "keepPatterns": "",
            "ignoredPaths": "",
            "largeFileMB": 500,
            "downloadsAgeDays": 30,
            "lifetimeFreed": 0,
        ])
    }

    static var thresholdGB: Int { defaults.integer(forKey: "thresholdGB") }

    static var lifetimeFreed: Int64 {
        get { Int64(defaults.integer(forKey: "lifetimeFreed")) }
        set { defaults.set(Int(newValue), forKey: "lifetimeFreed") }
    }

    static var ignoredPaths: [String] {
        get { lines("ignoredPaths") }
        set { defaults.set(newValue.joined(separator: "\n"), forKey: "ignoredPaths") }
    }

    @MainActor
    static func scanSettings() -> ScanSettings {
        ScanSettings(
            nodeRoots: lines("nodeRoots").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            keepPatterns: lines("keepPatterns"),
            nodeMinAgeDays: defaults.integer(forKey: "nodeMinAgeDays"),
            largeFileBytes: Int64(defaults.integer(forKey: "largeFileMB")) * 1_000_000,
            downloadsAgeDays: defaults.integer(forKey: "downloadsAgeDays"),
            runningApps: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        )
    }

    private static func lines(_ key: String) -> [String] {
        (defaults.string(forKey: key) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Disk
    @Published var freeBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var purgeableBytes: Int64 = 0
    @Published var volumeName = "Macintosh HD"
    @Published var fullDiskAccess = Scanner.hasFullDiskAccess()

    // Scanning and cleaning
    @Published var findings: [Category: Finding] = [:]
    @Published var selection: Set<String> = []
    @Published var scanning: Set<Category> = []
    @Published var scanTotal = 0
    @Published var cleaning = false
    @Published var cleanDone = 0
    @Published var cleanTotal = 0
    @Published var message: String?
    @Published var lastFreed: Int64 = 0
    @Published var undoable: [Trashed] = []
    @Published var lifetimeFreed = Prefs.lifetimeFreed

    // UI state, kept here because the Command Line Tools ship without SwiftUI's @State macro.
    @Published var route: Route? = .overview
    @Published var reviewing = false
    @Published var search = ""
    @Published var sort = ItemSort.size
    @Published var previewURL: URL?
    @Published var hovered: String?

    // Space Lens
    @Published var lensRoot = Scanner.home
    @Published var lensEntries: [LensEntry] = []
    @Published var lensLoading = false
    private var lensCache: [String: [LensEntry]] = [:]
    private var lensGeneration = 0

    private var timer: Timer?
    private var warned = false

    var isBusy: Bool { cleaning || !scanning.isEmpty }
    var isLow: Bool { freeBytes < Int64(Prefs.thresholdGB) * 1_000_000_000 }
    var hasScanned: Bool { !findings.isEmpty }
    var launchAtLogin: Bool { .enabled == SMAppService.mainApp.status }
    var reclaimable: Int64 { findings.values.reduce(0) { $0 + $1.size } }
    var usedFraction: Double { Double(totalBytes - freeBytes) / Double(max(totalBytes, 1)) }
    var reclaimableFraction: Double { min(Double(reclaimable) / Double(max(totalBytes, 1)), usedFraction) }
    var scanProgress: Double { 0 == scanTotal ? 0 : Double(scanTotal - scanning.count) / Double(scanTotal) }

    var selectedItems: [(Category, Item)] {
        Category.allCases.flatMap { category in
            (findings[category]?.items ?? []).filter { selection.contains($0.id) }.map { (category, $0) }
        }
    }

    init() {
        Prefs.register()
        refreshFree()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Reading the volume's free space is all the background work Deckswab does.
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
        Task { await check() }
    }

    // MARK: - Selection

    func selectedSize(where include: (Category) -> Bool = { _ in true }) -> Int64 {
        selectedItems.filter { include($0.0) }.reduce(0) { $0 + $1.1.size }
    }

    func selectedSize(in category: Category) -> Int64 {
        selectedSize { category == $0 }
    }

    func setSelected(_ on: Bool, _ items: [Item]) {
        let ids = items.map(\.id)
        if on {
            selection.formUnion(ids)
        } else {
            selection.subtract(ids)
        }
    }

    /// Items of a category as the list shows them: filtered by the search field and sorted.
    func visibleItems(_ category: Category) -> [Item] {
        var items = findings[category]?.items ?? []
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .size: items.sort { $0.size > $1.size }
        case .name: items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date: items.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        }
        return items
    }

    // MARK: - Disk

    func refreshFree() {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey, .volumeLocalizedNameKey,
        ]
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        freeBytes = Int64(values?.volumeAvailableCapacity ?? 0)
        totalBytes = Int64(values?.volumeTotalCapacity ?? 0)
        // Space macOS frees by itself when needed, such as local snapshots and iCloud copies.
        purgeableBytes = max(0, (values?.volumeAvailableCapacityForImportantUsage ?? 0) - freeBytes)
        volumeName = values?.volumeLocalizedName ?? volumeName
        fullDiskAccess = Scanner.hasFullDiskAccess()
    }

    // MARK: - Scan and clean

    func scan(_ categories: [Category] = Category.allCases) async {
        guard !isBusy else { return }
        scanning = Set(categories)
        scanTotal = categories.count
        let settings = Prefs.scanSettings()

        await withTaskGroup(of: Finding.self) { group in
            for category in categories {
                group.addTask { Scanner.scan(category, settings) }
            }
            for await finding in group {
                store(finding)
                scanning.remove(finding.category)
            }
        }

        removeOverlaps()
        refreshFree()
    }

    /// Removes the given items, or the current selection.
    @discardableResult
    func clean(_ work: [(Category, Item)]? = nil) async -> Int64 {
        let work = work ?? selectedItems
        guard !work.isEmpty, !isBusy else { return 0 }
        cleaning = true
        cleanDone = 0
        cleanTotal = work.count
        message = nil

        var cleaned = Set<String>()
        var freed: Int64 = 0
        var trashedSize: Int64 = 0
        var trashed: [Trashed] = []
        var errors: [String] = []

        for (category, item) in work {
            let result = await Task.detached { Result { try Scanner.clean(item, in: category) } }.value
            switch result {
            case .success(let moved):
                cleaned.insert(item.id)
                trashed += moved
                if category.movesToTrash {
                    trashedSize += item.size
                } else {
                    freed += item.size
                }
            case .failure(let error):
                errors.append("\(item.title): \(error.localizedDescription)")
            }
            cleanDone += 1
        }

        for category in findings.keys {
            findings[category]?.items.removeAll { cleaned.contains($0.id) }
        }
        selection.subtract(cleaned)
        cleaning = false
        reviewing = false
        refreshFree()

        lastFreed = freed
        undoable = trashed
        Prefs.lifetimeFreed += freed
        lifetimeFreed = Prefs.lifetimeFreed

        var parts: [String] = []
        if 0 < freed {
            parts.append("Freed \(fmt(freed)).")
        }
        if 0 < trashedSize {
            parts.append("Moved \(fmt(trashedSize)) to the Trash. Empty it to get that space back.")
        }
        if !errors.isEmpty {
            parts.append("\(errors.count) couldn't be removed: " + errors.prefix(3).joined(separator: "; "))
        }
        message = parts.joined(separator: " ")

        if 0 < trashedSize {
            await scan([.trash])
        }
        return freed
    }

    /// Puts back what the last clean moved to the Trash.
    func undo() async {
        let moves = undoable
        undoable = []
        var restored = 0
        for move in moves where !Scanner.fm.fileExists(atPath: move.original.path) {
            if nil != (try? Scanner.fm.moveItem(at: move.trashed, to: move.original)) {
                restored += 1
            }
        }
        message = "Put back \(restored) of \(moves.count) items."
        lastFreed = 0
        await scan(Category.allCases.filter(\.movesToTrash) + [.trash])
    }

    /// Hides an item from every future scan.
    func ignore(_ item: Item) {
        Prefs.ignoredPaths += [item.id]
        for category in findings.keys {
            findings[category]?.items.removeAll { $0.id == item.id }
        }
        selection.remove(item.id)
    }

    func trash(_ url: URL) {
        var result: NSURL?
        do {
            try Scanner.fm.trashItem(at: url, resultingItemURL: &result)
            undoable = [Trashed(original: url, trashed: (result as URL?) ?? url)]
            message = "Moved \(url.lastPathComponent) to the Trash."
            lastFreed = 0
            lensCache = [:]
            lensEntries.removeAll { $0.url == url }
            refreshFree()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Runs on a timer: warns once per low-space episode and, if enabled, cleans junk.
    func check() async {
        guard !isBusy else { return }
        refreshFree()
        guard isLow else {
            warned = false
            return
        }

        if Prefs.defaults.bool(forKey: "autoClean") {
            // Only data that is rebuilt on its own, and node_modules when asked.
            let categories = Category.allCases.filter { category in
                category.isAutomatic || (.projects == category && Prefs.defaults.bool(forKey: "autoCleanNodeModules"))
            }
            await scan(categories)
            let work = categories.flatMap { category in
                (findings[category]?.items ?? []).filter(\.preselected).map { (category, $0) }
            }
            let freed = await clean(work)
            if 0 < freed {
                notify("Freed \(fmt(freed)) automatically", "\(fmt(freeBytes)) free now.")
            }
        }

        if isLow && !warned {
            notify("Disk space is low", "Only \(fmt(freeBytes)) free. Open Deckswab to see what can go.")
            warned = true
        }
    }

    private func store(_ finding: Finding) {
        var finding = finding
        let ignored = Prefs.ignoredPaths
        finding.items.removeAll { item in ignored.contains { item.id == $0 || item.id.hasPrefix($0 + "/") } }
        finding.items.sort { $0.size > $1.size }
        selection.subtract(findings[finding.category]?.items.map(\.id) ?? [])
        selection.formUnion(finding.items.filter(\.preselected).map(\.id))
        findings[finding.category] = finding
    }

    /// A file can match several categories, such as an old installer in Downloads. Keep it in the first only.
    private func removeOverlaps() {
        var claimed: [String] = []
        for category in Category.allCases {
            guard var finding = findings[category] else { continue }
            finding.items.removeAll { item in claimed.contains { item.id == $0 || item.id.hasPrefix($0 + "/") } }
            claimed += finding.items.map(\.id)
            findings[category] = finding
        }
        selection.formIntersection(findings.values.flatMap { $0.items.map(\.id) })
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Space Lens

    func openLens(_ url: URL, refresh: Bool = false) async {
        lensRoot = url
        lensGeneration += 1
        let generation = lensGeneration
        if !refresh, let cached = lensCache[url.path] {
            lensEntries = cached
            lensLoading = false
            return
        }

        lensEntries = []
        lensLoading = true
        // Without Full Disk Access, reading other apps' containers makes macOS ask about each one.
        let skipping: Set<String> = fullDiskAccess ? [] : [
            Scanner.home.appending(path: "Library/Containers").path,
            Scanner.home.appending(path: "Library/Group Containers").path,
        ]
        let children = Scanner.children(of: url).filter { !skipping.contains($0.path) }

        await withTaskGroup(of: LensEntry.self) { group in
            for child in children {
                group.addTask { LensEntry(child, skipping: skipping) }
            }
            // Entries arrive as they're measured, so the map fills in while the big folders are still counting.
            for await entry in group where generation == lensGeneration && 0 < entry.size {
                lensEntries.append(entry)
                lensEntries.sort { $0.size > $1.size }
            }
        }

        guard generation == lensGeneration else { return }
        lensCache[url.path] = lensEntries
        lensLoading = false
    }

    func chooseLensFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = lensRoot
        panel.prompt = "Map"
        if .OK == panel.runModal(), let url = panel.url {
            Task { await openLens(url) }
        }
    }
}

struct LensEntry: Identifiable, Sendable {
    let url: URL
    let size: Int64
    /// A folder Space Lens can open. Packages such as apps count as files.
    let isFolder: Bool

    var id: String { url.path }
    var name: String { FileManager.default.displayName(atPath: url.path) }

    init(_ url: URL, skipping: Set<String>) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        self.url = url
        isFolder = true == values?.isDirectory && true != values?.isPackage
        size = Scanner.allocatedSize(url, skipping: skipping)
    }
}
