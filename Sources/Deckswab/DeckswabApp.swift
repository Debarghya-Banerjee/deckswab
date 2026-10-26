import ServiceManagement
import SwiftUI

@main
struct DeckswabApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Deckswab", id: "main") {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 700)
        // Size the window by hand only. Following the content's ideal size lets a long list grow it.
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Image(systemName: model.isLow ? "externaldrive.badge.exclamationmark" : "internaldrive")
            Text(fmt(model.freeBytes))
        }
        // The label is the one view that exists from launch, so it opens the window.
        // Started at login, Deckswab waits quietly in the menu bar instead.
        .task {
            if !model.launchAtLogin {
                openWindow(id: "main")
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    DiskRing(used: model.usedFraction, reclaimable: model.reclaimableFraction, isLow: model.isLow, lineWidth: 7)
                    Text("\(Int((model.usedFraction * 100).rounded()))%")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fmt(model.freeBytes)) available").font(.headline)
                    if model.isLow {
                        Text("Below your \(Prefs.thresholdGB) GB limit").font(.callout).foregroundStyle(.red)
                    } else {
                        Text("\(model.volumeName) · \(fmt(model.totalBytes))").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            if !model.scanning.isEmpty {
                ProgressView(value: model.scanProgress) {
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.hasScanned {
                VStack(spacing: 6) {
                    LegendRow(color: .green, label: "Can be cleaned", value: model.reclaimable)
                    LegendRow(color: .accentColor, label: "Selected", value: model.selectedSize())
                }
            }

            Divider()

            HStack {
                Button {
                    model.message = nil
                    Task { await model.scan() }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .disabled(model.isBusy)

                Button("Open Deckswab") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit Deckswab")
            }

            if 0 < model.lifetimeFreed {
                Text("Freed \(fmt(model.lifetimeFreed)) so far")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { model.refreshFree() }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ScanningSettings()
                .tabItem { Label("Scanning", systemImage: "magnifyingglass") }
            IgnoredSettings()
                .tabItem { Label("Ignored", systemImage: "eye.slash") }
        }
        .frame(width: 560, height: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage("thresholdGB") private var thresholdGB = 20
    @AppStorage("autoClean") private var autoClean = false
    @AppStorage("autoCleanNodeModules") private var autoCleanNodeModules = false

    var body: some View {
        Form {
            Section {
                Stepper("Warn when less than \(thresholdGB) GB is free", value: $thresholdGB, in: 5...200, step: 5)
                Toggle("Clean junk automatically when space is low", isOn: $autoClean)
                Toggle("Include old project dependencies", isOn: $autoCleanNodeModules)
                    .disabled(!autoClean)
            } header: {
                Text("Low disk space")
            } footer: {
                Text("Automatic cleaning only removes caches, logs and build data that are rebuilt on their own. It never touches your files, the Trash, Docker or leftovers.")
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { on in
                        if on {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                        model.objectWillChange.send()
                    }
                ))
            }

            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    if model.fullDiskAccess {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshFree() }
    }
}

struct ScanningSettings: View {
    @AppStorage("largeFileMB") private var largeFileMB = 500
    @AppStorage("downloadsAgeDays") private var downloadsAgeDays = 30
    @AppStorage("nodeMinAgeDays") private var nodeMinAgeDays = 14
    @AppStorage("nodeRoots") private var nodeRoots = Prefs.defaultRoots
    @AppStorage("keepPatterns") private var keepPatterns = ""

    var body: some View {
        Form {
            Section("Your files") {
                Stepper("Large files are \(largeFileMB) MB or more", value: $largeFileMB, in: 100...10_000, step: 100)
                Stepper("Old downloads were added \(downloadsAgeDays)+ days ago", value: $downloadsAgeDays, in: 1...365)
            }

            Section {
                Stepper("Skip projects changed in the last \(nodeMinAgeDays) days", value: $nodeMinAgeDays, in: 0...365)
                LabeledContent("Look in these folders") {
                    TextEditor(text: $nodeRoots).font(.body.monospaced()).frame(height: 90)
                }
                LabeledContent("Never delete paths containing") {
                    TextEditor(text: $keepPatterns).font(.body.monospaced()).frame(height: 60)
                }
            } header: {
                Text("Project dependencies")
            } footer: {
                Text("One per line. Covers node_modules, Python virtualenvs, Rust target folders and Next.js, Nuxt, Turborepo, Parcel and Angular caches.")
            }
        }
        .formStyle(.grouped)
    }
}

struct IgnoredSettings: View {
    @AppStorage("ignoredPaths") private var ignoredPaths = ""

    var body: some View {
        let paths = ignoredPaths.split(separator: "\n").map(String.init)

        Form {
            Section {
                if paths.isEmpty {
                    Text("Nothing ignored. Right-click an item and choose Always Ignore to hide it from scans.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(paths, id: \.self) { path in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                            Text(Scanner.tilde(URL(fileURLWithPath: path))).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                ignoredPaths = paths.filter { $0 != path }.joined(separator: "\n")
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop ignoring")
                        }
                    }
                }
            } header: {
                Text("Ignored items")
            } footer: {
                Text("Removed items show up again after the next scan.")
            }
        }
        .formStyle(.grouped)
    }
}
