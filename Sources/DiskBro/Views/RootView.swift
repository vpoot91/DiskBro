import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                Backdrop()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let toast = model.toast {
                    ToastView(toast: toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.scanState == .scanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(model.progress.files.formatted()) files").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                } else {
                    Button { model.startScan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .help("Rescan the whole disk (⌘R)")
                }
            }
        }
        .sheet(item: $model.trashRequest) { TrashReviewSheet(request: $0) }
        .sheet(item: $model.commandRequest) { CommandSheet(request: $0) }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView()
        case .explore: ExploreView()
        case .cleanup: CleanupView()
        case .largeFiles: LargeFilesView()
        case .duplicates: DuplicatesView()
        case .history: HistoryView()
        case .hidden: HiddenSpaceView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            Section {
                ForEach(AppSection.allCases) { s in
                    Label(s.title, systemImage: s.symbol)
                        .badge(badge(for: s))
                        .tag(s)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarStorageCard().padding(12) }
    }

    private func badge(for s: AppSection) -> Text? {
        switch s {
        case .cleanup where model.safeReclaimable > 0:
            Text(Fmt.bytes(model.safeReclaimable)).foregroundStyle(Palette.good)
        case .duplicates where (model.duplicateGroups?.count ?? 0) > 0:
            Text("\(model.duplicateGroups!.count)")
        default: nil
        }
    }
}

struct SidebarStorageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let v = model.volume
        let tint: Color = switch v.health { case .good: Palette.good; case .low: Palette.warning; case .critical: Palette.critical }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.bytes(v.available)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                Text("free").foregroundStyle(.secondary)
                Spacer()
                if v.health != .good {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
                        .help(v.health == .critical ? "Critically low. macOS needs ~20 GB free to run updates and keep swap healthy." : "Running low on space")
                }
            }
            SizeBar(fraction: 1 - v.freeFraction, tint: tint)
            Text("\(Fmt.bytes(v.used)) of \(Fmt.bytes(v.total)) used").font(.caption).foregroundStyle(.secondary)

            if let trash = model.trashSize, trash > 0 {
                Divider()
                HStack {
                    Label(Fmt.bytes(trash), systemImage: "trash").font(.callout).monospacedDigit()
                    Spacer()
                    Button("Empty") { model.requestEmptyTrash() }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
