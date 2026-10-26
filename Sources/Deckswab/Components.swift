import SwiftUI

extension Category {
    var color: Color {
        switch self {
        case .appCaches: .blue
        case .logs: .gray
        case .appUpdates: .cyan
        case .iosUpdates: .teal
        case .leftovers: .mint
        case .trash: Color(white: 0.55)
        case .devCaches: .orange
        case .xcode: .indigo
        case .docker: Color(red: 0.11, green: 0.55, blue: 0.93)
        case .homebrew: Color(red: 0.85, green: 0.6, blue: 0.2)
        case .projects: .green
        case .binlogs: .purple
        case .installers: .pink
        case .oldDownloads: Color(red: 0.95, green: 0.45, blue: 0.3)
        case .largeFiles: .red
        case .iosBackups: Color(white: 0.45)
        }
    }
}

/// A rounded square with a white symbol, like the icons in System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .frame(width: size, height: size)
    }
}

extension IconTile {
    init(_ category: Category, size: CGFloat = 22) {
        self.init(symbol: category.symbol, color: category.color, size: size)
    }
}

/// A rounded panel that sits on the window background.
struct Panel: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(highlighted ? 0.12 : 0.04), radius: highlighted ? 10 : 3, y: highlighted ? 4 : 1)
    }
}

extension View {
    func panel(highlighted: Bool = false) -> some View {
        modifier(Panel(highlighted: highlighted))
    }
}

/// The used part of the disk as a ring, with the part Deckswab could free in green at its end.
struct DiskRing: View {
    let used: Double
    let reclaimable: Double
    let isLow: Bool
    var lineWidth: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: used)
                .stroke(
                    AngularGradient(colors: isLow ? [.orange, .red] : [.cyan, .blue, .indigo], center: .center, startAngle: .zero, endAngle: .degrees(360 * used)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            if 0 < reclaimable {
                Circle()
                    .trim(from: max(0, used - reclaimable), to: used)
                    .stroke(Color.green.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(-90))
        .animation(.spring(duration: 0.8), value: used)
        .animation(.spring(duration: 0.8), value: reclaimable)
    }
}

struct LegendRow: View {
    let color: Color
    let label: String
    let value: Int64

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color.gradient).frame(width: 9, height: 9)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(fmt(value)).monospacedDigit().contentTransition(.numericText())
        }
        .font(.callout)
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "lock.shield.fill", color: .orange, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Give Deckswab Full Disk Access").bold()
                Text("It's needed to see the Trash, device backups and app containers. Scan again after turning it on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The file's Finder icon, or the category's tile for things that aren't files.
struct ItemIcon: View {
    let item: Item
    let category: Category

    var body: some View {
        if item.isOnDisk {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            IconTile(category, size: 24).frame(width: 28, height: 28)
        }
    }
}

// MARK: - Cleaning

struct CleanBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let selected = model.selectedSize()

        HStack(spacing: 12) {
            if let message = model.message {
                Image(systemName: 0 < model.lastFreed || !model.undoable.isEmpty ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(0 < model.lastFreed || !model.undoable.isEmpty ? .green : .secondary)
                    .font(.title3)
                    .symbolEffect(.bounce, value: model.lastFreed)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if !model.undoable.isEmpty {
                    Button("Undo") { Task { await model.undo() } }
                        .disabled(model.isBusy)
                }
            }
            Spacer()
            if 0 < selected {
                Text("\(fmt(selected)) selected")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Button {
                model.reviewing = true
            } label: {
                Label(model.cleaning ? "Cleaning…" : "Review & Clean", systemImage: "sparkles")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.isBusy || 0 == selected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.default, value: model.message)
    }
}

/// Shown before anything is removed: what goes, how much, and whether it can come back.
struct ReviewSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let selected = model.selectedItems
        let categories = Category.allCases.filter { category in selected.contains { $0.0 == category } }
        let permanent = model.selectedSize { !$0.movesToTrash }
        let trashed = model.selectedSize { $0.movesToTrash }

        VStack(spacing: 0) {
            VStack(spacing: 10) {
                IconTile(symbol: "sparkles", color: .accentColor, size: 52)
                Text("Clean \(fmt(permanent + trashed))?").font(.title2.bold())
                VStack(spacing: 2) {
                    if 0 < permanent {
                        Label("\(fmt(permanent)) of junk is deleted. Apps rebuild it when needed.", systemImage: "xmark.bin")
                    }
                    if 0 < trashed {
                        Label("\(fmt(trashed)) goes to the Trash, so you can put it back.", systemImage: "trash")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(24)

            List(categories) { category in
                let items = selected.filter { $0.0 == category }
                HStack(spacing: 10) {
                    IconTile(category, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.title)
                        Text("\(items.count) \(1 == items.count ? "item" : "items")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(fmt(model.selectedSize(in: category))).monospacedDigit()
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: min(CGFloat(categories.count) * 44 + 12, 260))
            .padding(.horizontal, 24)

            Group {
                if model.cleaning {
                    ProgressView(value: Double(model.cleanDone), total: Double(max(model.cleanTotal, 1))) {
                        Text("Cleaning \(min(model.cleanDone + 1, model.cleanTotal)) of \(model.cleanTotal)…").font(.callout)
                    }
                } else {
                    HStack {
                        Button("Cancel") { model.reviewing = false }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button {
                            Task { await model.clean() }
                        } label: {
                            Text("Clean").frame(minWidth: 80)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.large)
                }
            }
            .padding(24)
        }
        .frame(width: 480)
        .interactiveDismissDisabled(model.cleaning)
    }
}
