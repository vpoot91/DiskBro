import SwiftUI

struct TrashReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TrashRequest

    @State private var included: Set<String> = []
    @State private var emptyAfterwards = false
    @State private var working = false
    @State private var failures: [String] = []

    private var selected: [TrashItem] { request.items.filter { included.contains($0.id) } }
    private var total: Int64 { selected.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: request.isEmptyTrash ? "trash.slash.fill" : "trash.fill")
                    .font(.system(size: 26)).foregroundStyle(Palette.critical)
                    .frame(width: 44, height: 44)
                    .background(Palette.critical.opacity(0.12), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.isEmptyTrash ? request.title : "Review before moving to Trash").font(.title2.weight(.semibold))
                    Text(request.isEmptyTrash
                         ? "This permanently deletes everything in the Trash and frees \(Fmt.bytes(total)). You can't undo this."
                         : "\(request.title). You can restore items from the Trash until it's emptied.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            if !request.isEmptyTrash {
                Divider()
                List {
                    ForEach(request.items) { item in
                        Toggle(isOn: Binding(get: { included.contains(item.id) },
                                             set: { if $0 { included.insert(item.id) } else { included.remove(item.id) } })) {
                            HStack(spacing: 10) {
                                PathIcon(path: item.url.path, size: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).lineLimit(1)
                                    Text(Fmt.tildePath(item.url.path)).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 160, maxHeight: 340)
            }

            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Some items couldn't be moved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).font(.callout.weight(.semibold))
                    ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 24).padding(.top, 12)
            }

            Divider().padding(.top, 12)
            HStack(spacing: 12) {
                if !request.isEmptyTrash {
                    Toggle("Empty Trash afterwards", isOn: $emptyAfterwards)
                        .toggleStyle(.checkbox)
                        .help("Frees the space immediately, but you can't put items back.")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Fmt.bytes(total)).font(.headline).monospacedDigit()
                    Text(request.isEmptyTrash || emptyAfterwards ? "will be freed" : "to Trash").font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button {
                    working = true
                    Task {
                        let req = TrashRequest(title: request.title, items: selected, isEmptyTrash: request.isEmptyTrash)
                        let result = await model.executeTrash(req, emptyAfterwards: emptyAfterwards)
                        working = false
                        if result.failed.isEmpty { dismiss() } else { failures = result.failed }
                    }
                } label: {
                    if working { ProgressView().controlSize(.small).frame(width: 120) }
                    else { Text(request.isEmptyTrash ? "Empty Trash" : (emptyAfterwards ? "Delete \(selected.count) Items" : "Move \(selected.count) to Trash")).frame(minWidth: 120) }
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.critical)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || working || !failures.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 620)
        .onAppear { included = Set(request.items.map(\.id)) }
    }
}

struct CommandSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: CommandRequest

    @State private var running = false
    @State private var result: ShellResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "terminal.fill").font(.system(size: 24)).foregroundStyle(.tint)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title).font(.title2.weight(.semibold))
                    Text(request.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(request.admin ? "DiskBro will run this as administrator:" : "DiskBro will run:").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(request.commandLines.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(12)
                .background(Palette.track, in: .rect(cornerRadius: 10))
            }

            if let result {
                VStack(alignment: .leading, spacing: 6) {
                    Label(result.status == 0 ? "Finished" : "Finished with errors (exit \(result.status))",
                          systemImage: result.status == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.status == 0 ? Palette.good : Palette.warning).font(.callout.weight(.semibold))
                    ScrollView {
                        Text(result.combined.isEmpty ? "(no output)" : result.combined)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .padding(10)
                    .background(Palette.track, in: .rect(cornerRadius: 10))
                }
            }

            HStack {
                if let size = request.estimatedSize, size > 0, result == nil {
                    Text("Frees about \(Fmt.bytes(size))").font(.headline)
                }
                Spacer()
                if result == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button {
                        running = true
                        Task { result = await model.runCommand(request); running = false }
                    } label: {
                        if running { ProgressView().controlSize(.small).frame(width: 80) } else { Text("Run").frame(minWidth: 80) }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}
