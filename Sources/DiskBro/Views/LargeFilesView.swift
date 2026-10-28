import SwiftUI

struct LargeFileRow: Identifiable {
    var id: ObjectIdentifier { node.id }
    let node: FileNode
    let name: String
    let folder: String
    let size: Int64
    let lastUsed: Date
    let kind: FileKind
}

struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [LargeFileRow] = []
    @State private var kind: FileKind = .all
    @State private var minSize: Int64 = 100 << 20
    @State private var hideSystem = true
    @State private var olderThan = 0
    @State private var search = ""
    @State private var selection = Set<ObjectIdentifier>()
    @State private var sortOrder = [KeyPathComparator(\LargeFileRow.size, order: .reverse)]
    @State private var loading = false

    private var filtered: [LargeFileRow] {
        rows.filter { r in
            (kind == .all || r.kind == kind)
                && (olderThan == 0 || Date.now.timeIntervalSince(r.lastUsed) > Double(olderThan) * 86_400)
                && (search.isEmpty || r.name.localizedCaseInsensitiveContains(search) || r.folder.localizedCaseInsensitiveContains(search))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        if model.root == nil {
            ScanPrompt()
        } else {
            let visible = filtered
            let selected = visible.filter { selection.contains($0.id) }
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    PageHeader("Large Files", subtitle: "\(visible.count.formatted()) files · \(Fmt.bytes(visible.reduce(0) { $0 + $1.size }))") {
                        TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                    HStack(spacing: 12) {
                        Picker("Kind", selection: $kind) {
                            ForEach(FileKind.allCases) { k in Label(k.rawValue, systemImage: k.symbol).tag(k) }
                        }
                        .frame(width: 170)
                        Picker("At least", selection: $minSize) {
                            Text("10 MB").tag(Int64(10 << 20))
                            Text("50 MB").tag(Int64(50 << 20))
                            Text("100 MB").tag(Int64(100 << 20))
                            Text("500 MB").tag(Int64(500 << 20))
                            Text("1 GB").tag(Int64(1 << 30))
                        }
                        .frame(width: 160)
                        Picker("Not used for", selection: $olderThan) {
                            Text("Any time").tag(0)
                            Text("1 month").tag(30)
                            Text("3 months").tag(90)
                            Text("6 months").tag(180)
                            Text("1 year").tag(365)
                        }
                        .frame(width: 200)
                        Toggle("Hide system files", isOn: $hideSystem).toggleStyle(.switch).controlSize(.small)
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)

                Table(visible, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { r in
                        HStack(spacing: 8) {
                            FileIcon(node: r.node, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).lineLimit(1).truncationMode(.middle)
                                Text(r.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        .contextMenu { NodeContextMenu(node: r.node) }
                    }
                    .width(min: 260, ideal: 460)
                    TableColumn("Size", value: \.size) { r in
                        Text(Fmt.bytes(r.size)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Last Used", value: \.lastUsed) { r in
                        Text(Fmt.age(r.lastUsed)).foregroundStyle(.secondary)
                    }
                    .width(100)
                    TableColumn("Kind", value: \.kind.rawValue) { r in
                        Label(r.kind.rawValue, systemImage: r.kind.symbol).foregroundStyle(.secondary)
                    }
                    .width(110)
                }
                .contextMenu(forSelectionType: ObjectIdentifier.self) { _ in } primaryAction: { ids in
                    if let r = visible.first(where: { ids.contains($0.id) }) { model.reveal(r.node.url) }
                }
                .onDeleteCommand { model.requestTrash(selected.map(\.node)) }

                if !selected.isEmpty {
                    HStack {
                        Text("\(selected.count) selected · \(Fmt.bytes(selected.reduce(0) { $0 + $1.size }))").font(.callout.weight(.medium))
                        Spacer()
                        Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.node.url)) }
                            .buttonStyle(.glass)
                        Button("Move to Trash…", systemImage: "trash") { model.requestTrash(selected.map(\.node)) }
                            .buttonStyle(.glassProminent).tint(Palette.critical)
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .padding(12)
                }
            }
            .task(id: "\(model.treeVersion)-\(minSize)-\(hideSystem)") { await load() }
        }
    }

    private func load() async {
        guard let root = model.root else { return }
        loading = true
        let min = minSize, hide = hideSystem
        let home = model.home
        let result = await Task.detached(priority: .userInitiated) { () -> [LargeFileRow] in
            let systemRoots: Set<String> = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library", "/opt", "/cores", home + "/Library"]
            var out: [LargeFileRow] = []
            func visit(_ n: FileNode, path: String) {
                for c in n.children {
                    let p = path == "/" ? "/" + c.name : path + "/" + c.name
                    if c.size < min { break } // sorted by size
                    if c.isDirectory {
                        if hide && (systemRoots.contains(p) || c.isPackage) { continue }
                        visit(c, path: p)
                    } else if !c.isAggregate {
                        out.append(LargeFileRow(node: c, name: c.name, folder: Fmt.tildePath(path), size: c.size,
                                                lastUsed: c.lastUsed, kind: FileKind.of(c.name)))
                    }
                }
            }
            visit(root, path: root.name)
            return out
        }.value
        rows = result
        selection = selection.filter { id in result.contains { $0.id == id } }
        loading = false
    }
}
