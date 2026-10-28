import SwiftUI
import AppKit

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.72), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

/// Soft tinted backdrop so content cards and glass controls have something to sit on.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                Palette.series[0].opacity(0.10), .clear, Palette.series[6].opacity(0.08),
                .clear, .clear, .clear,
                Palette.series[2].opacity(0.05), .clear, Palette.series[0].opacity(0.06),
            ])
        }
        .ignoresSafeArea()
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

struct SectionTitle: View {
    let text: String
    var detail: String?
    init(_ text: String, detail: String? = nil) { self.text = text; self.detail = detail }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.headline)
            Spacer()
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Badges & tiles

struct SafetyBadge: View {
    let safety: Safety
    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(safety.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(safety.color.opacity(0.12), in: .capsule)
            .help(safety.hint)
    }
}

struct StatTile: View {
    let title: String
    let value: Int64
    let symbol: String
    var tint: Color = .accentColor
    var footnote: String?

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                let (num, unit) = Fmt.bytesParts(value)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(num).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(unit).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                .contentTransition(.numericText())
                if let footnote {
                    Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Circle().fill(tint).frame(width: 7, height: 7).padding(14)
        }
    }
}

struct SizeBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(tint).frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Capacity bar

struct CapacitySegment: Identifiable {
    let id: String
    let label: String
    let size: Int64
    let color: Color
    var symbol: String = "circle.fill"
}

struct CapacityBar: View {
    let segments: [CapacitySegment]
    let total: Int64
    var height: CGFloat = 26
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geo in
                let visible = segments.filter { $0.size > 0 }
                let gaps = CGFloat(max(0, visible.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(visible) { seg in
                        let w = max(3, (geo.size.width - gaps) * CGFloat(Double(seg.size) / Double(max(total, 1))))
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(seg.color)
                            .opacity(hovered == nil || hovered == seg.id ? 1 : 0.35)
                            .frame(width: w)
                            .onHover { hovered = $0 ? seg.id : nil }
                            .help("\(seg.label): \(Fmt.bytes(seg.size))")
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovered)
            }
            .frame(height: height)
            .background(Palette.track, in: .rect(cornerRadius: 6, style: .continuous))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(segments) { seg in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(seg.color).frame(width: 10, height: 10)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator, lineWidth: seg.id == "free" ? 1 : 0))
                        Text(seg.label).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.bytes(seg.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(hovered == seg.id ? Palette.track : .clear, in: .rect(cornerRadius: 6))
                    .onHover { hovered = $0 ? seg.id : nil }
                }
            }
        }
    }
}

// MARK: - Icons

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        if let img = cache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 4000 { cache.removeAll() }
        cache[path] = img
        return img
    }
}

struct FileIcon: View {
    let node: FileNode
    var size: CGFloat = 20
    var body: some View {
        Group {
            if node.isAggregate {
                Image(systemName: "square.grid.3x3.fill").resizable().scaledToFit()
                    .foregroundStyle(.tertiary).padding(size * 0.12)
            } else {
                Image(nsImage: IconCache.icon(for: node.path)).resizable().interpolation(.high)
            }
        }
        .frame(width: size, height: size)
    }
}

struct PathIcon: View {
    let path: String
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: IconCache.icon(for: path)).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

// MARK: - Empty & progress states

struct ScanPrompt: View {
    @Environment(AppModel.self) private var model
    var message = "Scan your disk to see what's taking up space."

    var body: some View {
        VStack(spacing: 18) {
            if model.scanState == .scanning {
                ScanProgressPanel()
            } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text(message).font(.title3).foregroundStyle(.secondary)
                Button { model.startScan() } label: {
                    Label("Scan Macintosh HD", systemImage: "magnifyingglass").padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanProgressPanel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let used = max(model.volume.used, 1)
        let fraction = min(0.99, Double(model.progress.bytes) / Double(used))
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(Palette.track, lineWidth: 10)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
                VStack(spacing: 2) {
                    Text(Fmt.bytes(model.progress.bytes)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text("\(model.progress.files.formatted()) files").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 150, height: 150)
            Text("Scanning…").font(.headline)
            Text(Fmt.tildePath(model.progress.currentPath))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
            Button("Stop", role: .cancel) { model.cancelScan() }.buttonStyle(.glass)
        }
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(toast.isError ? Palette.critical : .primary)
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Context menu for nodes

struct NodeContextMenu: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    var body: some View {
        if node.isRealItem {
            Button("Open", systemImage: "arrow.up.forward.app") { model.open(node.url) }
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(node.url) }
            if node.isDirectory { Button("Explore", systemImage: "chart.pie") { model.explore(node) } }
            Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(node.url) }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.requestTrash([node]) }
        } else if let parent = node.parent {
            Button("Reveal Folder in Finder", systemImage: "folder") { model.open(parent.url) }
        }
    }
}
