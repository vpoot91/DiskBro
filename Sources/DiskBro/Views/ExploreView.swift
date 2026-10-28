import SwiftUI

struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: FileNode?
    @State private var selection = Set<FileNode>()

    var body: some View {
        if let root = model.root, let focus = model.exploreFocus ?? model.root {
            let _ = model.treeVersion
            VStack(spacing: 0) {
                breadcrumb(focus: focus, root: root)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                HStack(spacing: 0) {
                    SunburstView(focus: focus, hovered: $hovered) { node in
                        if node.isDirectory { withAnimation(.snappy) { model.exploreFocus = node } }
                    } onCenterTap: {
                        if let p = focus.parent { withAnimation(.snappy) { model.exploreFocus = p } }
                    }
                    .padding(24)
                    .frame(minWidth: 380, maxWidth: .infinity)

                    Divider()
                    childList(focus: focus)
                        .frame(minWidth: 380, idealWidth: 460, maxWidth: 560)
                }
            }
            .onChange(of: focus) { selection.removeAll() }
        } else {
            ScanPrompt()
        }
    }

    private func breadcrumb(focus: FileNode, root: FileNode) -> some View {
        HStack(spacing: 6) {
            Button { if let p = focus.parent { withAnimation(.snappy) { model.exploreFocus = p } } } label: {
                Image(systemName: "chevron.left").frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .disabled(focus.parent == nil)
            .keyboardShortcut(.upArrow, modifiers: .command)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(focus.ancestors) { n in
                        Button { withAnimation(.snappy) { model.exploreFocus = n } } label: {
                            HStack(spacing: 5) {
                                FileIcon(node: n, size: 16)
                                Text(n.displayName).lineLimit(1)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(n === focus ? Palette.track : .clear, in: .rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        if n !== focus { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                    }
                }
            }
            Spacer()
            Button("Home", systemImage: "house") { withAnimation(.snappy) { model.exploreFocus = root.node(atPath: model.home) } }
                .buttonStyle(.glass)
            Button("Reveal", systemImage: "folder") { model.reveal(focus.url) }
                .buttonStyle(.glass)
        }
    }

    private func childList(focus: FileNode) -> some View {
        let items = focus.children
        let maxSize = max(items.first?.size ?? 1, 1)
        let selectedSize = selection.reduce(0) { $0 + $1.size }
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("\(Fmt.bytes(focus.size)) · \(focus.fileCount.formatted()) files").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

            List(selection: $selection) {
                ForEach(items) { n in
                    ExploreRow(node: n, fraction: Double(n.size) / Double(maxSize),
                               colorIndex: focus.children.firstIndex(of: n) ?? 99,
                               highlighted: hovered.map { $0 === n || $0.isDescendant(of: n) } ?? false)
                        .tag(n)
                        .contextMenu { NodeContextMenu(node: n) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: FileNode.self) { _ in } primaryAction: { nodes in
                if let n = nodes.first, n.isDirectory { withAnimation(.snappy) { model.exploreFocus = n } }
                else if let n = nodes.first, n.isRealItem { model.open(n.url) }
            }
            .onDeleteCommand { model.requestTrash(Array(selection)) }

            if !selection.isEmpty {
                HStack {
                    Text("\(selection.count) selected · \(Fmt.bytes(selectedSize))").font(.callout.weight(.medium))
                    Spacer()
                    Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(selection.map(\.url)) }
                        .buttonStyle(.glass)
                    Button("Move to Trash…", systemImage: "trash") { model.requestTrash(Array(selection)) }
                        .buttonStyle(.glassProminent).tint(Palette.critical)
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selection.isEmpty)
    }
}

struct ExploreRow: View {
    let node: FileNode
    let fraction: Double
    let colorIndex: Int
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(node: node, size: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(node.displayName).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(node.isAggregate ? .secondary : .primary)
                    if node.isDenied {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help("macOS didn't allow reading this folder. Grant Full Disk Access.")
                    }
                    Spacer()
                    Text(Fmt.bytes(node.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                SizeBar(fraction: fraction, tint: SunburstView.color(index: colorIndex, aggregate: node.isAggregate))
            }
            if node.isDirectory && !node.isPackage {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(highlighted ? Palette.track : .clear, in: .rect(cornerRadius: 6))
    }
}

// MARK: - Sunburst

struct SunburstView: View {
    let focus: FileNode
    @Binding var hovered: FileNode?
    var onSelect: (FileNode) -> Void
    var onCenterTap: () -> Void

    private let rings = 4
    private let minAngle = 0.006

    struct Segment {
        let node: FileNode
        let start: Double
        let end: Double
        let depth: Int
        let colorIndex: Int
    }

    static func color(index: Int, aggregate: Bool) -> Color {
        if aggregate || index >= 7 { return Palette.neutral }
        return Palette.series[index]
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        func layout(_ node: FileNode, start: Double, span: Double, depth: Int, colorIndex: Int) {
            guard depth <= rings, node.size > 0 else { return }
            var a = start
            for (i, c) in node.children.enumerated() {
                let s = span * Double(c.size) / Double(node.size)
                if s < minAngle { break } // children are sorted; the rest are smaller
                let ci = depth == 1 ? i : colorIndex
                result.append(Segment(node: c, start: a, end: a + s, depth: depth, colorIndex: ci))
                if c.isDirectory { layout(c, start: a, span: s, depth: depth + 1, colorIndex: ci) }
                a += s
            }
        }
        layout(focus, start: 0, span: 2 * .pi, depth: 1, colorIndex: 0)
        return result
    }

    var body: some View {
        let segs = segments
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = side / 2 - 4
            let inner = outer * 0.26
            let ring = (outer - inner) / CGFloat(rings)

            ZStack {
                Canvas { ctx, _ in
                    let gap = Color(nsColor: .windowBackgroundColor)
                    for s in segs {
                        let r0 = inner + ring * CGFloat(s.depth - 1) + 1
                        let r1 = r0 + ring - 1
                        var p = Path()
                        p.addArc(center: center, radius: r1, startAngle: .radians(s.start - .pi / 2), endAngle: .radians(s.end - .pi / 2), clockwise: false)
                        p.addArc(center: center, radius: r0, startAngle: .radians(s.end - .pi / 2), endAngle: .radians(s.start - .pi / 2), clockwise: true)
                        p.closeSubpath()
                        let base = Self.color(index: s.colorIndex, aggregate: s.node.isAggregate)
                        let depthFade = [1.0, 0.78, 0.6, 0.45][min(s.depth - 1, 3)]
                        let isHot = hovered.map { $0 === s.node || s.node.isDescendant(of: $0) } ?? false
                        let dim = hovered != nil && !isHot
                        ctx.fill(p, with: .color(base.opacity(dim ? depthFade * 0.35 : depthFade)))
                        ctx.stroke(p, with: .color(gap), lineWidth: 1.5)
                    }
                }

                // Center label
                VStack(spacing: 4) {
                    let n = hovered ?? focus
                    if hovered == nil, focus.parent != nil {
                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(n.displayName).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                    Text(Fmt.bytes(n.size)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    if hovered != nil, focus.size > 0 {
                        Text(String(format: "%.1f%%", Double(n.size) / Double(focus.size) * 100)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(n.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: inner * 1.7)
                .position(center)
                .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt): hovered = hit(pt, center: center, inner: inner, ring: ring, segs: segs)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                let dx = value.location.x - center.x, dy = value.location.y - center.y
                if hypot(dx, dy) < inner { onCenterTap(); return }
                if let n = hit(value.location, center: center, inner: inner, ring: ring, segs: segs) {
                    hovered = nil
                    onSelect(n)
                }
            })
            .contextMenu {
                if let h = hovered { NodeContextMenu(node: h) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.snappy(duration: 0.25), value: focus)
    }

    private func hit(_ pt: CGPoint, center: CGPoint, inner: CGFloat, ring: CGFloat, segs: [Segment]) -> FileNode? {
        let dx = pt.x - center.x, dy = pt.y - center.y
        let r = hypot(dx, dy)
        guard r >= inner else { return nil }
        let depth = Int((r - inner) / ring) + 1
        guard depth <= rings else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return segs.first { $0.depth == depth && angle >= $0.start && angle < $0.end }?.node
    }
}
