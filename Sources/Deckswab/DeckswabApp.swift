import ServiceManagement
import SwiftUI

@main
struct DeckswabApp: App {
    @StateObject private var monitor = DiskMonitor()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(monitor)
        } label: {
            HStack {
                Image(systemName: monitor.isLow ? "externaldrive.badge.exclamationmark" : "internaldrive")
                Text(fmt(monitor.freeBytes))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject private var monitor: DiskMonitor

    var body: some View {
        Group {
            if monitor.showSettings {
                SettingsView { monitor.showSettings = false }
            } else {
                main
            }
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { monitor.refreshFree() }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(fmt(monitor.freeBytes)) free of \(fmt(monitor.totalBytes))").font(.headline)
                ProgressView(value: Double(monitor.totalBytes - monitor.freeBytes), total: Double(max(monitor.totalBytes, 1)))
                    .tint(monitor.isLow ? .red : .accentColor)
                if monitor.isLow {
                    Text("Below your \(Prefs.thresholdGB) GB limit").font(.caption).foregroundStyle(.red)
                }
            }

            Divider()

            if monitor.findings.isEmpty {
                Text("Scan to see what can be cleaned.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(monitor.findings) { FindingRow(finding: $0) }
                    }
                }
                .frame(maxHeight: 360)
            }

            if let message = monitor.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            if monitor.confirming {
                HStack {
                    Text("Permanently delete \(fmt(monitor.selectedSize))?")
                    Spacer()
                    Button("Cancel") { monitor.confirming = false }
                    Button("Delete", role: .destructive) {
                        monitor.confirming = false
                        Task { await monitor.clean(monitor.selected) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else {
                HStack {
                    Button(monitor.busy ?? "Scan") { Task { await monitor.scan() } }
                        .disabled(nil != monitor.busy)
                    Button("Clean \(fmt(monitor.selectedSize))") { monitor.confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(nil != monitor.busy || 0 == monitor.selectedSize)
                    Spacer()
                    Button { monitor.showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless)
                        .help("Settings")
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                        .buttonStyle(.borderless)
                        .help("Quit Deckswab")
                }
            }
        }
    }
}

struct FindingRow: View {
    @EnvironmentObject private var monitor: DiskMonitor
    let finding: Finding

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { monitor.expanded.contains(finding.category) },
            set: { open in
                if open {
                    monitor.expanded.insert(finding.category)
                } else {
                    monitor.expanded.remove(finding.category)
                }
            }
        )) {
            ForEach(finding.items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(fmt(item.size)).monospacedDigit()
                }
            }
        } label: {
            Toggle(isOn: Binding(
                get: { monitor.selected.contains(finding.category) },
                set: { on in
                    if on {
                        monitor.selected.insert(finding.category)
                    } else {
                        monitor.selected.remove(finding.category)
                    }
                }
            )) {
                HStack {
                    Text(finding.category.title)
                    Spacer()
                    Text(fmt(finding.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .disabled(finding.items.isEmpty)
        }
    }
}

struct SettingsView: View {
    let done: () -> Void

    @AppStorage("thresholdGB") private var thresholdGB = 20
    @AppStorage("autoClean") private var autoClean = false
    @AppStorage("autoCleanNodeModules") private var autoCleanNodeModules = false
    @AppStorage("nodeMinAgeDays") private var nodeMinAgeDays = 14
    @AppStorage("nodeRoots") private var nodeRoots = Prefs.defaultRoots
    @AppStorage("keepPatterns") private var keepPatterns = Prefs.defaultKeep
    @EnvironmentObject private var monitor: DiskMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(.headline)

            Stepper("Warn when less than \(thresholdGB) GB is free", value: $thresholdGB, in: 5...200, step: 5)
            Toggle("Clean caches and binlogs automatically when low", isOn: $autoClean)
            Toggle("Also clean old node_modules automatically", isOn: $autoCleanNodeModules)
                .disabled(!autoClean)
                .padding(.leading, 20)

            Divider()

            Stepper("node_modules unused for \(nodeMinAgeDays)+ days", value: $nodeMinAgeDays, in: 0...365)
            Text("Look for node_modules in (one folder per line)").font(.caption)
            TextEditor(text: $nodeRoots).font(.body.monospaced()).frame(height: 54)
            Text("Never delete paths containing (one per line)").font(.caption)
            TextEditor(text: $keepPatterns).font(.body.monospaced()).frame(height: 54)

            Divider()

            Toggle("Open at login", isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { on in
                    if on {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? SMAppService.mainApp.unregister()
                    }
                    monitor.objectWillChange.send()
                }
            ))

            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
    }
}
