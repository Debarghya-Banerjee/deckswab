import SwiftUI

/// A map of what takes up space in a folder. Folders open on click, like DaisyDisk.
struct SpaceLensView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let total = model.lensEntries.reduce(0) { $0 + $1.size }

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.openLens(model.lensRoot.deletingLastPathComponent()) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled("/" == model.lensRoot.path)
                .help("Enclosing folder")

                Breadcrumbs()
                Spacer()
                if model.lensLoading {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.callout).foregroundStyle(.secondary)
                }
                Text(fmt(total))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Button {
                    Task { await model.openLens(model.lensRoot, refresh: true) }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(model.lensLoading)
                .help("Measure again")
                Button {
                    model.chooseLensFolder()
                } label: {
                    Image(systemName: "folder.badge.questionmark")
                }
                .help("Map another folder or disk")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Treemap(entries: Array(model.lensEntries.prefix(80)), total: total)
                .frame(minHeight: 200, maxHeight: 340)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            Divider()

            if model.lensEntries.isEmpty && !model.lensLoading {
                ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Nothing here takes up space."))
            } else {
                List(model.lensEntries) { entry in
                    LensRow(entry: entry, total: total)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .navigationTitle("Space Lens")
        .task {
            if model.lensEntries.isEmpty && !model.lensLoading {
                await model.openLens(model.lensRoot)
            }
        }
    }
}

struct Breadcrumbs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // From the home folder down, or from the disk when outside it.
        let home = Scanner.home.path
        let base = model.lensRoot.path.hasPrefix(home) ? Scanner.home : URL(fileURLWithPath: "/")
        let parts = model.lensRoot.path.dropFirst(base.path.count).split(separator: "/")
        let crumbs = [base] + parts.indices.map { i in parts[...i].reduce(base) { $0.appending(path: String($1)) } }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, url in
                    if 0 < index {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button {
                        Task { await model.openLens(url) }
                    } label: {
                        HStack(spacing: 4) {
                            if 0 == index {
                                Image(systemName: url == Scanner.home ? "house.fill" : "internaldrive.fill")
                            }
                            Text(0 == index && url == Scanner.home ? "Home" : FileManager.default.displayName(atPath: url.path))
                        }
                        .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                        .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct LensRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: LensEntry
    let total: Int64

    var body: some View {
        let fraction = Double(entry.size) / Double(max(total, 1))

        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            if entry.isFolder {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Capsule()
                .fill(.quaternary)
                .frame(width: 120, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor.gradient).frame(width: max(2, 120 * fraction))
                }
            Text(fraction < 0.001 ? "<0.1%" : String(format: "%.1f%%", fraction * 100))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            Text(fmt(entry.size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(entry) }
        .contextMenu { LensMenu(entry: entry) }
    }

    private func open(_ entry: LensEntry) {
        if entry.isFolder {
            Task { await model.openLens(entry.url) }
        } else {
            model.previewURL = entry.url
        }
    }
}

struct LensMenu: View {
    @EnvironmentObject private var model: AppModel
    let entry: LensEntry

    var body: some View {
        if entry.isFolder {
            Button("Open") { Task { await model.openLens(entry.url) } }
        }
        Button("Quick Look") { model.previewURL = entry.url }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trash(entry.url) }
    }
}

struct Treemap: View {
    @EnvironmentObject private var model: AppModel
    let entries: [LensEntry]
    let total: Int64

    var body: some View {
        GeometryReader { geometry in
            let rects = squarify(entries.map { Double($0.size) }, in: CGRect(origin: .zero, size: geometry.size))

            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(entries, rects).enumerated()), id: \.element.0.id) { index, pair in
                    Tile(entry: pair.0, index: index, rect: pair.1)
                }
            }
            .animation(.spring(duration: 0.35), value: entries.map(\.id))
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    struct Tile: View {
        @EnvironmentObject private var model: AppModel
        let entry: LensEntry
        let index: Int
        let rect: CGRect

        var body: some View {
            let hovered = model.hovered == entry.id
            // Golden-ratio steps keep neighbouring tiles' colours apart.
            let hue = (Double(index) * 0.618_034 + 0.55).truncatingRemainder(dividingBy: 1)
            let color = Color(hue: hue, saturation: entry.isFolder ? 0.5 : 0.25, brightness: hovered ? 0.95 : 0.82)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.gradient)
                .overlay(alignment: .topLeading) {
                    if 64 < rect.width && 34 < rect.height {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(fmt(entry.size)).font(.caption2).monospacedDigit().opacity(0.85)
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .padding(6)
                    }
                }
                .padding(1.5)
                .frame(width: max(0, rect.width), height: max(0, rect.height))
                .contentShape(Rectangle())
                .onHover { model.hovered = $0 ? entry.id : (hovered ? nil : model.hovered) }
                .onTapGesture {
                    if entry.isFolder {
                        Task { await model.openLens(entry.url) }
                    } else {
                        model.previewURL = entry.url
                    }
                }
                .contextMenu { LensMenu(entry: entry) }
                .help("\(entry.name) · \(fmt(entry.size))")
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

/// Lays out values, largest first, as rectangles whose areas match them and whose
/// sides stay close to square (Bruls, Huizing and van Wijk's squarified treemap).
func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
    let sum = values.reduce(0, +)
    guard 0 < sum, 0 < rect.width, 0 < rect.height else { return values.map { _ in .zero } }
    let areas = values.map { $0 * rect.width * rect.height / sum }

    func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
        let total = row.reduce(0, +)
        guard let largest = row.max(), let smallest = row.min(), 0 < smallest else { return .infinity }
        return max(side * side * largest / (total * total), total * total / (side * side * smallest))
    }

    var result: [CGRect] = []
    var remaining = rect
    var start = 0
    while start < areas.count {
        let side = min(remaining.width, remaining.height)
        var end = start + 1
        while end < areas.count && worst(areas[start...end], side) <= worst(areas[start..<end], side) {
            end += 1
        }

        let row = areas[start..<end]
        let rowArea = row.reduce(0, +)
        if remaining.width >= remaining.height {
            // A column along the left edge.
            let width = rowArea / remaining.height
            var y = remaining.minY
            for area in row {
                let height = area / width
                result.append(CGRect(x: remaining.minX, y: y, width: width, height: height))
                y += height
            }
            remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: remaining.width - width, height: remaining.height)
        } else {
            // A row along the top edge.
            let height = rowArea / remaining.width
            var x = remaining.minX
            for area in row {
                let width = area / height
                result.append(CGRect(x: x, y: remaining.minY, width: width, height: height))
                x += width
            }
            remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: remaining.height - height)
        }
        start = end
    }
    return result
}
