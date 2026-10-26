import QuickLook
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            Group {
                switch model.route ?? .overview {
                case .overview:
                    OverviewView()
                case .lens:
                    SpaceLensView()
                case .category(let category):
                    CategoryView(category: category)
                }
            }
            // Every page fills the pane. A shorter one makes the split view resize, which knocks the sidebar out of place.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) { CleanBar() }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.message = nil
                    Task { await model.scan() }
                } label: {
                    Label("Smart Scan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(model.isBusy)
                .help("Scan everything again (⌘R)")
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .sheet(isPresented: $model.reviewing) { ReviewSheet().environmentObject(model) }
        .quickLookPreview($model.previewURL)
        .onChange(of: model.route) { model.search = "" }
        // A menu bar app only shows in the Dock while its window is open.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.route) {
            Section {
                Label {
                    Text("Overview")
                } icon: {
                    IconTile(symbol: "gauge.with.dots.needle.67percent", color: .accentColor)
                }
                .tag(Route.overview)

                Label {
                    Text("Space Lens")
                } icon: {
                    IconTile(symbol: "square.grid.3x3.square", color: .teal)
                }
                .tag(Route.lens)
            }

            ForEach(CategoryGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.categories) { category in
                        HStack {
                            Label {
                                Text(category.title)
                            } icon: {
                                IconTile(category)
                            }
                            Spacer()
                            if model.scanning.contains(category) {
                                ProgressView().controlSize(.mini)
                            } else if let finding = model.findings[category], 0 < finding.size {
                                Text(fmt(finding.size))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(Route.category(category))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HeroCard()

                if !model.fullDiskAccess {
                    FullDiskAccessBanner()
                }

                if model.hasScanned || model.isBusy {
                    ForEach(CategoryGroup.allCases) { group in
                        GroupSection(group: group)
                    }
                } else {
                    Features()
                }

                if 0 < model.lifetimeFreed {
                    Label("Deckswab has freed \(fmt(model.lifetimeFreed)) on this Mac so far.", systemImage: "leaf.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }
}

struct HeroCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 36) {
            ZStack {
                DiskRing(used: model.usedFraction, reclaimable: model.reclaimableFraction, isLow: model.isLow, lineWidth: 20)
                VStack(spacing: 0) {
                    Text(fmt(model.freeBytes))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("available").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                        Text(model.volumeName).font(.title2.bold())
                        if model.isLow {
                            Text("LOW")
                                .font(.caption2.weight(.heavy))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text(model.isLow ? "Below your \(Prefs.thresholdGB) GB limit. Let's find some space." : "\(Int((model.usedFraction * 100).rounded()))% of \(fmt(model.totalBytes)) used")
                        .foregroundStyle(model.isLow ? .red : .secondary)
                }

                VStack(spacing: 6) {
                    LegendRow(color: model.isLow ? .red : .blue, label: "Used", value: model.totalBytes - model.freeBytes)
                    if model.hasScanned {
                        LegendRow(color: .green, label: "Can be cleaned", value: model.reclaimable)
                    }
                    if 0 < model.purgeableBytes {
                        LegendRow(color: .gray, label: "Purgeable", value: model.purgeableBytes)
                            .help("Space macOS frees by itself when it's needed, such as local snapshots and iCloud copies")
                    }
                }
                .frame(maxWidth: 360)

                ScanControls()
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .panel()
    }
}

struct ScanControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.scanning.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.scanProgress)
                    .frame(maxWidth: 360)
                    .animation(.default, value: model.scanProgress)
                Text("Scanning… \(model.scanTotal - model.scanning.count) of \(model.scanTotal) areas checked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    model.message = nil
                    Task { await model.scan() }
                } label: {
                    Label(model.hasScanned ? "Scan Again" : "Smart Scan", systemImage: "magnifyingglass")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.hasScanned ? .secondary : .accentColor)
                .controlSize(.large)
                .disabled(model.cleaning)

                if 0 < model.selectedSize() {
                    Button {
                        model.reviewing = true
                    } label: {
                        Label("Clean \(fmt(model.selectedSize()))", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }
            }
        }
    }
}

struct GroupSection: View {
    @EnvironmentObject private var model: AppModel
    let group: CategoryGroup

    var body: some View {
        let total = group.categories.reduce(0) { $0 + (model.findings[$1]?.size ?? 0) }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.rawValue).font(.title3.bold())
                Text(group == .files ? "Moved to the Trash" : "Deleted, rebuilt when needed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(fmt(total)).foregroundStyle(.secondary).monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(group.categories) { CategoryCard(category: $0) }
            }
        }
    }
}

struct CategoryCard: View {
    @EnvironmentObject private var model: AppModel
    let category: Category

    var body: some View {
        let finding = model.findings[category]
        let size = finding?.size ?? 0
        let selected = model.selectedSize(in: category)
        let isScanning = model.scanning.contains(category)
        let isHovered = model.hovered == category.id

        Button {
            model.route = .category(category)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    IconTile(category, size: 34)
                    Spacer()
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else if 0 < selected {
                        Label(fmt(selected), systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                            .monospacedDigit()
                    } else if nil != finding?.note {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Text(category.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline) {
                    Text(isScanning ? "—" : fmt(size))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    if let finding, !isScanning {
                        Text("\(finding.items.count) \(1 == finding.items.count ? "item" : "items")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(highlighted: isHovered)
            .opacity(0 == size && !isScanning ? 0.6 : 1)
            .scaleEffect(isHovered ? 1.015 : 1)
            .animation(.spring(duration: 0.25), value: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { model.hovered = $0 ? category.id : (model.hovered == category.id ? nil : model.hovered) }
        .help(category.summary)
    }
}

/// What a scan covers, shown before the first one.
struct Features: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What Smart Scan looks for").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(CategoryGroup.allCases) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.rawValue).font(.headline)
                        ForEach(group.categories) { category in
                            Label {
                                Text(category.title).font(.callout)
                            } icon: {
                                IconTile(category, size: 20)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel()
                }
            }
            Label("Nothing is removed until you review it. Your own files go to the Trash, and you can undo.", systemImage: "checkmark.shield.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Category

struct CategoryView: View {
    @EnvironmentObject private var model: AppModel
    let category: Category

    var body: some View {
        let finding = model.findings[category]
        let all = finding?.items ?? []
        let items = model.visibleItems(category)

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(category, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title).font(.title2.bold())
                    Text(category.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(fmt(finding?.size ?? 0))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Label(
                        category.movesToTrash ? "Moves to Trash" : "Deletes permanently",
                        systemImage: category.movesToTrash ? "arrow.uturn.backward.circle" : "xmark.bin"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((category.movesToTrash ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                    .foregroundStyle(category.movesToTrash ? .green : .orange)
                }
            }
            .padding(20)

            if let note = finding?.note {
                Group {
                    if Scanner.fullDiskAccessNote == note {
                        FullDiskAccessBanner()
                    } else {
                        Label(note, systemImage: "info.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            if model.scanning.contains(category) {
                ProgressView("Scanning \(category.title.lowercased())…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if nil == finding {
                ContentUnavailableView {
                    Label("Not scanned yet", systemImage: category.symbol)
                } description: {
                    Text("Scan to see what's here.")
                } actions: {
                    Button("Scan \(category.title)") { Task { await model.scan([category]) } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else if all.isEmpty {
                ContentUnavailableView("Nothing to clean", systemImage: "checkmark.seal.fill", description: Text("This area is already tidy."))
                    .frame(maxHeight: .infinity)
            } else {
                FilterBar()
                Divider()
                if items.isEmpty {
                    ContentUnavailableView.search(text: model.search)
                        .frame(maxHeight: .infinity)
                } else {
                List {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { items.allSatisfy { model.selection.contains($0.id) } },
                            set: { model.setSelected($0, items) }
                        )) {
                            Text("Select all \(items.count) \(model.search.isEmpty ? "items" : "matches")")
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        Text("\(fmt(model.selectedSize(in: category))) selected")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    ForEach(items) { ItemRow(item: $0, category: category) }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                }
            }
        }
        .navigationTitle(category.title)
    }
}

/// Filter and sort controls for a category list. They live in the page rather than the
/// toolbar: changing the toolbar per page breaks NavigationSplitView's sidebar layout.
struct FilterBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(maxWidth: 280)

            Spacer()

            Picker("Sort by", selection: $model.sort) {
                ForEach(ItemSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct ItemRow: View {
    @EnvironmentObject private var model: AppModel
    let item: Item
    let category: Category

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selection.contains(item.id) },
                set: { model.setSelected($0, [item]) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            ItemIcon(item: item, category: category)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(fmt(item.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isOnDisk { model.previewURL = item.url }
        }
        .contextMenu {
            if item.isOnDisk {
                Button("Quick Look") { model.previewURL = item.url }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url] + item.extra)
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url.path, forType: .string)
                }
                Divider()
            }
            Button("Always Ignore") { model.ignore(item) }
        }
    }
}
