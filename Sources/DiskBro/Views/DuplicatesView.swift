import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var minSize: Int64 = 5 << 20

    var body: some View {
        if model.root == nil {
            ScanPrompt()
        } else {
            let _ = model.treeVersion
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader("Duplicates", subtitle: "Identical files in your home folder, matched by content (SHA-256), not just by name.") {
                        if model.duplicateProgress == nil {
                            Picker("Min size", selection: $minSize) {
                                Text("1 MB").tag(Int64(1 << 20))
                                Text("5 MB").tag(Int64(5 << 20))
                                Text("25 MB").tag(Int64(25 << 20))
                                Text("100 MB").tag(Int64(100 << 20))
                            }
                            .frame(width: 150)
                            Button(model.duplicateGroups == nil ? "Find Duplicates" : "Search Again", systemImage: "magnifyingglass") {
                                model.findDuplicates(minSize: minSize)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }

                    if let p = model.duplicateProgress {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(p.phase).font(.headline)
                                    Spacer()
                                    Button("Stop") { model.cancelDuplicates() }.buttonStyle(.glass)
                                }
                                ProgressView(value: p.fraction)
                                Text("\(p.done.formatted()) of \(p.total.formatted()) candidate files").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if let groups = model.duplicateGroups {
                        if groups.isEmpty {
                            Card {
                                VStack(spacing: 10) {
                                    Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(Palette.good)
                                    Text("No duplicates found").font(.headline)
                                }
                                .frame(maxWidth: .infinity, minHeight: 140)
                            }
                        } else {
                            summary(groups)
                            ForEach(groups) { g in DuplicateGroupCard(group: g) }
                        }
                    } else {
                        Card {
                            VStack(spacing: 12) {
                                Image(systemName: "square.on.square.dashed").font(.system(size: 40, weight: .light)).foregroundStyle(.tint)
                                Text("Searches Documents, Desktop, Downloads, Movies, Pictures, your projects and other folders. App bundles and Library data are skipped because they often contain identical files on purpose.")
                                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
                            }
                            .frame(maxWidth: .infinity, minHeight: 180)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.treeVersion) { model.pruneDuplicateGroups() }
        }
    }

    private func summary(_ groups: [DuplicateGroup]) -> some View {
        let wasted = groups.reduce(0) { $0 + $1.wasted }
        let extras = groups.flatMap { g in g.files.filter { $0 !== model.duplicateKeep[g.id] } }
        return Card(padding: 18) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Fmt.bytes(wasted)) in duplicate copies").font(.title3.weight(.semibold))
                    Text("\(groups.count) sets. The copy marked Keep in each set stays; the rest go to the Trash. Note: copies made with Finder's Duplicate on APFS may share storage, so the space you get back can be smaller.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Trash All Extra Copies…", systemImage: "trash") {
                    model.requestTrash(extras, title: "Trash \(extras.count) duplicate copies")
                }
                .buttonStyle(.glassProminent).tint(Palette.critical)
            }
        }
    }
}

struct DuplicateGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        let keep = model.duplicateKeep[group.id]
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    FileIcon(node: group.files[0], size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.files[0].name).font(.headline).lineLimit(1)
                        Text("\(group.files.count) copies · \(Fmt.bytes(group.size)) each").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.bytes(group.wasted)).font(.headline).monospacedDigit()
                        Text("reclaimable").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Trash Extras") {
                        model.requestTrash(group.files.filter { $0 !== keep }, title: "Trash duplicates of “\(group.files[0].name)”")
                    }
                    .buttonStyle(.glass)
                }
                .padding(16)
                Divider()
                ForEach(group.files) { f in
                    HStack(spacing: 10) {
                        Button {
                            model.duplicateKeep[group.id] = f
                        } label: {
                            Image(systemName: f === keep ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(f === keep ? Palette.good : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Keep this copy")
                        Text(f === keep ? "Keep" : "Trash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(f === keep ? Palette.good : Palette.critical)
                            .frame(width: 40, alignment: .leading)
                        Text(Fmt.tildePath(f.path)).lineLimit(1).truncationMode(.middle).font(.callout)
                        Spacer()
                        Text("Modified \(Fmt.age(f.modifiedDate))").font(.caption).foregroundStyle(.secondary)
                        Button { model.reveal(f.url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .contextMenu { NodeContextMenu(node: f) }
                }
            }
        }
    }
}
