import Foundation

/// Your own files. These are never preselected (except installers) and go to the Trash.
extension Scanner {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    static func installers() -> [Item] {
        ["Downloads", "Desktop"]
            .flatMap { walk(home.appending(path: $0)) { installerExtensions.contains($0.pathExtension.lowercased()) } }
            .compactMap { url in
                let date = added(url)
                return item(url, title: url.lastPathComponent, detail: "Added \(relative(date))", date: date)
            }
    }

    static func oldDownloads(_ settings: ScanSettings) -> [Item] {
        let cutoff = Date().addingTimeInterval(-Double(settings.downloadsAgeDays) * 86_400)
        return children(of: home.appending(path: "Downloads"))
            .filter { !$0.lastPathComponent.hasPrefix(".") && added($0) < cutoff }
            .compactMap { url in
                let date = added(url)
                return item(url, title: url.lastPathComponent, detail: "Added \(relative(date))", preselected: false, date: date)
            }
    }

    static func largeFiles(_ settings: ScanSettings) -> [Item] {
        walk(home) { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), true == values.isRegularFile else {
                return false
            }
            return settings.largeFileBytes <= Int64(values.fileSize ?? 0)
        }
        .compactMap { url in
            item(url, title: url.lastPathComponent, detail: tilde(url.deletingLastPathComponent()), preselected: false, date: modified(url))
        }
    }

    static func iosBackups() -> Finding {
        let root = home.appending(path: "Library/Application Support/MobileSync/Backup")
        guard fm.fileExists(atPath: root.path) else { return Finding(category: .iosBackups, items: []) }
        guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return Finding(category: .iosBackups, items: [], note: fullDiskAccessNote)
        }

        return Finding(category: .iosBackups, items: urls.compactMap { url in
            let info = NSDictionary(contentsOf: url.appending(path: "Info.plist"))
            let date = info?["Last Backup Date"] as? Date
            return item(
                url,
                title: info?["Device Name"] as? String ?? url.lastPathComponent,
                detail: date.map { "Backed up \(relative($0))" } ?? "Backup",
                preselected: false,
                date: date
            )
        })
    }
}
