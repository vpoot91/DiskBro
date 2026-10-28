import SwiftUI

struct HiddenSpaceView: View {
    @Environment(AppModel.self) private var model
    @State private var deletingSnapshots = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader("Hidden Space", subtitle: "Where the space goes that Finder doesn't show: “System Data”, swap, snapshots and protected files.") {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshSystemInfo() } }
                        .buttonStyle(.glass)
                }
                reconciliation
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) { purgeableCard; swapCard }
                    VStack(spacing: 20) { snapshotsCard; deniedCard }
                }
                tipsCard
            }
            .padding(28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Reconciliation

    private var reconciliation: some View {
        let v = model.volume
        let c = model.container
        let scannedData = model.root?.size ?? 0
        let system = c?.volume(role: "System")?.used ?? 0
        let data = c?.volume(role: "Data")?.used ?? 0
        let vm = c?.volume(role: "VM")?.used ?? 0
        let otherVols = (c?.volumes ?? []).filter { !["System", "Data", "VM"].contains($0.role) }.reduce(0) { $0 + $1.used }
        let invisible = model.root == nil ? 0 : max(0, system + data - scannedData)
        let segs: [CapacitySegment] = [
            CapacitySegment(id: "files", label: model.root == nil ? "Files (scan to measure)" : "Files the scan can see", size: model.root == nil ? system + data : scannedData, color: Palette.series[0]),
            CapacitySegment(id: "invisible", label: "Not visible to scan", size: invisible, color: Palette.series[1]),
            CapacitySegment(id: "vm", label: "Swap & sleep image", size: vm, color: Palette.series[2]),
            CapacitySegment(id: "other", label: "Preboot, Recovery & Update", size: otherVols, color: Palette.series[3]),
            CapacitySegment(id: "free", label: "Free", size: v.available, color: .clear),
        ]
        return Card(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle("Where every byte goes", detail: c.map { "APFS container · \(Fmt.bytes($0.capacity))" })
                CapacityBar(segments: segs, total: c?.capacity ?? v.total)
                if let c {
                    Divider()
                    VStack(spacing: 8) {
                        ForEach(c.volumes) { vol in
                            HStack {
                                Text(vol.friendlyName)
                                Text(vol.name).font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                                Text(Fmt.bytes(vol.used)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
                if invisible > 2_000_000_000 {
                    Label("\(Fmt.bytes(invisible)) is used but not visible to the scan. This is usually local snapshots, files in protected folders\(model.hasFullDiskAccess ? "" : " (grant Full Disk Access to see more)"), and APFS metadata.",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var purgeableCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Purgeable space", systemImage: "arrow.3.trianglepath").font(.headline)
                Text(Fmt.bytes(model.volume.purgeable)).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                Text("Space macOS can free on its own when needed, such as iCloud files with local copies and caches it manages. It counts as used in Finder, but apps can still use it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var swapCard: some View {
        let vm = model.container?.volume(role: "VM")?.used ?? 0
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Swap & sleep image", systemImage: "memorychip").font(.headline)
                Text(Fmt.bytes(vm)).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                Text(vm > 4_000_000_000
                     ? "macOS moves memory to disk when RAM runs out. Quitting memory-heavy apps (browsers with many tabs, Docker, simulators) or restarting your Mac shrinks this right away."
                     : "Memory macOS has moved to disk. It shrinks automatically, and restarting clears it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var snapshotsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Local Time Machine snapshots", systemImage: "clock.arrow.circlepath").font(.headline)
                    Spacer()
                    Text("\(model.snapshots.count)").font(.headline).monospacedDigit()
                }
                if model.snapshots.isEmpty {
                    Text("None right now. Snapshots can quietly hold tens of GB of deleted files, so check here if free space doesn't go up after cleaning.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Snapshots keep deleted files on disk until they expire (usually 24 h). Deleting them frees that space immediately.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(model.snapshots.prefix(6)) { s in
                        Text(s.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? s.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Button {
                        deletingSnapshots = true
                        Task { await model.deleteSnapshots(); deletingSnapshots = false }
                    } label: {
                        if deletingSnapshots { ProgressView().controlSize(.small) } else { Label("Delete All Snapshots…", systemImage: "trash") }
                    }
                    .buttonStyle(.glassProminent).tint(Palette.critical)
                    .help("Requires your administrator password")
                }
            }
        }
    }

    private var deniedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Folders macOS kept private", systemImage: "lock").font(.headline)
                    Spacer()
                    Text("\(model.deniedCount)").font(.headline).monospacedDigit()
                }
                if !model.hasFullDiskAccess {
                    Text("Without Full Disk Access these folders can't be measured.").font(.callout).foregroundStyle(.secondary)
                    Button("Grant Full Disk Access") { Permissions.openFullDiskAccessSettings() }.buttonStyle(.glass)
                } else {
                    Text("Even with Full Disk Access, some system folders stay protected by macOS. That's normal.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.deniedPaths.filter { $0.hasPrefix(model.home) }.prefix(8), id: \.self) { p in
                    Text(Fmt.tildePath(p)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var tipsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Tips for a small disk")
                tip("arrow.clockwise.circle", "Restart now and then", "This clears swap, temporary files and stale caches that only go away on reboot.")
                tip("icloud", "Use “Optimize Mac Storage”", "In System Settings ▸ Apple Account ▸ iCloud ▸ Drive, enable it to keep only recent files locally.")
                tip("message", "Let Messages expire", "Messages ▸ Settings ▸ General ▸ Keep messages: 1 Year stops attachments piling up forever.")
                tip("arrow.down.circle", "Clear Downloads monthly", "It's the #1 place where installers and one-time files pile up.")
                tip("hammer", "Xcode users", "Remove simulator runtimes you don't test on. Each one is 5–10 GB.")
            }
        }
    }

    private func tip(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
