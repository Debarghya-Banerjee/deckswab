import Foundation
import ServiceManagement
import UserNotifications

func fmt(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

enum Prefs {
    static let defaults = UserDefaults.standard
    static let defaultRoots = "~/Developer\n~/Projects\n~/Sites\n~/Local Sites"
    static let defaultKeep = ""

    static func register() {
        defaults.register(defaults: [
            "thresholdGB": 20,
            "autoClean": false,
            "autoCleanNodeModules": false,
            "nodeMinAgeDays": 14,
            "nodeRoots": defaultRoots,
            "keepPatterns": defaultKeep,
        ])
    }

    static var thresholdGB: Int { defaults.integer(forKey: "thresholdGB") }

    static var cleaner: CleanerSettings {
        CleanerSettings(
            nodeRoots: lines("nodeRoots").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            keepPatterns: lines("keepPatterns"),
            nodeMinAgeDays: defaults.integer(forKey: "nodeMinAgeDays")
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
final class DiskMonitor: ObservableObject {
    @Published var freeBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var findings: [Finding] = []
    @Published var selected: Set<Category> = [.binlogs, .appUpdates, .devCaches]
    @Published var busy: String?
    @Published var message: String?

    // Panel UI state, kept here because the Command Line Tools ship without SwiftUI's @State macro.
    @Published var showSettings = false
    @Published var confirming = false
    @Published var expanded: Set<Category> = []

    private var timer: Timer?
    private var warned = false

    var isLow: Bool { freeBytes < Int64(Prefs.thresholdGB) * 1_000_000_000 }

    var launchAtLogin: Bool { .enabled == SMAppService.mainApp.status }

    var selectedSize: Int64 {
        findings.filter { selected.contains($0.category) }.reduce(0) { $0 + $1.size }
    }

    init() {
        Prefs.register()
        refreshFree()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
        Task { await check() }
    }

    func refreshFree() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        freeBytes = Int64(values?.volumeAvailableCapacity ?? 0)
        totalBytes = Int64(values?.volumeTotalCapacity ?? 0)
    }

    /// Runs on a timer: warns once per low-space episode and, if enabled, cleans the safe categories.
    func check() async {
        guard nil == busy else { return }
        refreshFree()
        guard isLow else {
            warned = false
            return
        }

        if Prefs.defaults.bool(forKey: "autoClean") {
            var auto: Set<Category> = [.binlogs, .appUpdates, .devCaches]
            if Prefs.defaults.bool(forKey: "autoCleanNodeModules") {
                auto.insert(.nodeModules)
            }
            await scan(auto)
            let freed = await clean(auto)
            if 0 < freed {
                notify("Freed \(fmt(freed)) automatically", "\(fmt(freeBytes)) free now.")
            }
        }

        if isLow && !warned {
            notify("Disk space is low", "Only \(fmt(freeBytes)) free. Open Deckswab to see what can go.")
            warned = true
        }
    }

    func scan(_ categories: Set<Category> = Set(Category.allCases)) async {
        busy = "Scanning…"
        let settings = Prefs.cleaner
        let results = await Task.detached {
            categories.map { Finding(category: $0, items: Cleaner.scan($0, settings: settings)) }
        }.value

        findings = Category.allCases.compactMap { category in
            results.first { $0.category == category } ?? findings.first { $0.category == category }
        }
        busy = nil
    }

    @discardableResult
    func clean(_ categories: Set<Category>) async -> Int64 {
        busy = "Cleaning…"
        let items = findings.filter { categories.contains($0.category) }.flatMap(\.items)
        let (freed, errors) = await Task.detached {
            var freed: Int64 = 0
            var errors: [String] = []
            for item in items {
                do {
                    try Cleaner.clean(item)
                    freed += item.size
                } catch {
                    errors.append("\(item.title): \(error.localizedDescription)")
                }
            }
            return (freed, errors)
        }.value

        busy = nil
        refreshFree()
        message = errors.isEmpty
            ? "Freed \(fmt(freed))."
            : "Freed \(fmt(freed)). \(errors.count) failed: \(errors.joined(separator: "; "))"
        await scan(categories)
        return freed
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
