import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var filter: Safety?

    var body: some View {
        if model.root == nil {
            ScanPrompt(message: "Scan your disk to get personal cleanup recommendations.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader("Cleanup", subtitle: "Recommendations based on what's actually on your disk. Everything goes to the Trash first.") {
                        if model.recommendationsLoading { ProgressView().controlSize(.small) }
                    }
                    summary
                    filterBar
                    ForEach(RecommendationGroup.allCases, id: \.self) { group in
                        let recs = model.recommendations.filter { $0.group == group && (filter == nil || $0.safety == filter) }
                        if !recs.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionTitle(group.title, detail: Fmt.bytes(recs.reduce(0) { $0 + $1.totalSize }))
                                ForEach(recs) { rec in
                                    RecommendationCard(rec: rec, expanded: Binding(
                                        get: { expanded.contains(rec.id) },
                                        set: { if $0 { expanded.insert(rec.id) } else { expanded.remove(rec.id) } }))
                                }
                            }
                        }
                    }
                    if model.recommendations.isEmpty && !model.recommendationsLoading {
                        Card { Text("Nothing obvious to clean up.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var safeTrashRecs: [Recommendation] {
        model.recommendations.filter { r in
            guard r.safety == .safe, case .trash = r.action else { return false }
            return true
        }
    }

    private var summary: some View {
        let safe = safeTrashRecs
        let safeSize = safe.reduce(0) { $0 + model.selectedSize(of: $1) }
        return Card(padding: 22) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().fill(Palette.good.opacity(0.14))
                    Image(systemName: "sparkles").font(.system(size: 26, weight: .semibold)).foregroundStyle(Palette.good)
                }
                .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    let (num, unit) = Fmt.bytesParts(safeSize)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(num).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(unit).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        Text("safe to clean right now").font(.title3).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                    Text("Plus \(Fmt.bytes(model.reviewReclaimable)) worth reviewing. You'd have \(Fmt.bytes(model.volume.available + safeSize + (model.trashSize ?? 0))) free after cleaning the safe items and emptying the Trash.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let items = safe.flatMap { model.selectedEntries(of: $0) }
                        .map { TrashItem(url: $0.url, name: $0.name, size: $0.size, node: $0.node) }
                    if !items.isEmpty { model.trashRequest = TrashRequest(title: "Clean all safe items", items: items) }
                } label: {
                    Label("Clean All Safe Items", systemImage: "wand.and.stars").padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.good)
                .controlSize(.large)
                .disabled(safeSize == 0)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterChip(nil, "All")
            filterChip(.safe, "Safe")
            filterChip(.review, "Review")
            filterChip(.careful, "Careful")
            Spacer()
            Text(filter?.hint ?? "Safety ratings tell you how much to think before deleting.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func filterChip(_ s: Safety?, _ label: String) -> some View {
        Button {
            withAnimation(.snappy) { filter = s }
        } label: {
            HStack(spacing: 5) {
                if let s { Image(systemName: s.symbol).foregroundStyle(s.color) }
                Text(label)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .tint(filter == s ? Color.accentColor : nil)
        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: filter == s ? 1.5 : 0))
    }
}

struct RecommendationCard: View {
    @Environment(AppModel.self) private var model
    let rec: Recommendation
    @Binding var expanded: Bool

    var body: some View {
        let selectedSize = model.selectedSize(of: rec)
        let selection = model.selections[rec.id] ?? []
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: rec.symbol)
                        .font(.title2).foregroundStyle(rec.safety.color)
                        .frame(width: 44, height: 44)
                        .background(rec.safety.color.opacity(0.12), in: .rect(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(rec.title).font(.headline)
                            SafetyBadge(safety: rec.safety)
                        }
                        Text(rec.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(Fmt.bytes(rec.totalSize)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                        actionButton(selectedSize: selectedSize, selectionCount: selection.count)
                    }
                }
                .padding(18)

                if !rec.entries.isEmpty {
                    Divider()
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        HStack {
                            Text(expanded ? "Hide items" : "Show \(rec.entries.count) item\(rec.entries.count == 1 ? "" : "s")")
                            if rec.isActionable && !rec.entries.isEmpty {
                                Text("· \(selection.count) selected, \(Fmt.bytes(selectedSize))").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .font(.callout)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        entryList(selection: selection)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(selectedSize: Int64, selectionCount: Int) -> some View {
        switch rec.action {
        case .trash:
            Button("Move to Trash…") { model.perform(rec) }
                .buttonStyle(.glass).disabled(selectionCount == 0)
        case .emptyTrash:
            Button("Empty Trash…") { model.perform(rec) }.buttonStyle(.glassProminent).tint(Palette.critical)
        case .command(_, _, let perEntry, _):
            Button(perEntry ? "Delete Selected…" : "Run Cleanup…") { model.perform(rec) }
                .buttonStyle(.glass).disabled(perEntry && selectionCount == 0)
        case let .guidance(title, url):
            if url != nil { Button(title) { model.perform(rec) }.buttonStyle(.glass) }
        }
    }

    private func entryList(selection: Set<String>) -> some View {
        VStack(spacing: 0) {
            if rec.isActionable, rec.entries.count > 1, !isCommandWithoutSelection {
                HStack {
                    Button("Select All") { model.selections[rec.id] = Set(rec.entries.map(\.id)) }
                    Button("Select None") { model.selections[rec.id] = [] }
                    Spacer()
                }
                .buttonStyle(.link).font(.caption)
                .padding(.horizontal, 18).padding(.bottom, 6)
            }
            let maxSize = max(rec.entries.first?.size ?? 1, 1)
            ForEach(rec.entries.prefix(200)) { e in
                HStack(spacing: 10) {
                    if rec.isActionable && !isCommandWithoutSelection {
                        Toggle("", isOn: Binding(
                            get: { selection.contains(e.id) },
                            set: { on in
                                var s = model.selections[rec.id] ?? []
                                if on { s.insert(e.id) } else { s.remove(e.id) }
                                model.selections[rec.id] = s
                            }))
                        .toggleStyle(.checkbox).labelsHidden()
                    }
                    PathIcon(path: e.url.path, size: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        if let d = e.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                    Spacer()
                    SizeBar(fraction: Double(e.size) / Double(maxSize), tint: rec.safety.color.opacity(0.7)).frame(width: 80)
                    Text(Fmt.bytes(e.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    Button { model.reveal(e.url) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Reveal in Finder")
                }
                .padding(.horizontal, 18).padding(.vertical, 6)
                .contextMenu {
                    Button("Reveal in Finder") { model.reveal(e.url) }
                    if let n = e.node, n.isDirectory { Button("Explore") { model.explore(n) } }
                    Button("Copy Path") { model.copyPath(e.url) }
                }
            }
            if rec.entries.count > 200 {
                Text("+ \(rec.entries.count - 200) more").font(.caption).foregroundStyle(.secondary).padding(8)
            }
        }
        .padding(.bottom, 10)
    }

    private var isCommandWithoutSelection: Bool {
        if case .command(_, _, let perEntry, _) = rec.action { return !perEntry }
        if case .emptyTrash = rec.action { return true }
        return false
    }
}
