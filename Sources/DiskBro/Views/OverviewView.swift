import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if model.volume.health != .good { HealthBanner(volume: model.volume) }
                if !model.hasFullDiskAccess { FullDiskAccessCard() }

                if model.scanState == .scanning && model.root == nil {
                    Card { ScanProgressPanel().frame(maxWidth: .infinity).padding(.vertical, 20) }
                } else if model.root != nil {
                    tiles
                    HStack(alignment: .top, spacing: 20) {
                        TopRecommendationsCard()
                        BiggestFoldersCard()
                    }
                } else {
                    Card { ScanPrompt().frame(height: 260) }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        let v = model.volume
        let (num, unit) = Fmt.bytesParts(v.available)
        return Card(padding: 24) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Macintosh HD", systemImage: "internaldrive.fill")
                            .font(.headline).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(num).font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText())
                            Text(unit).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                            Text("available").font(.title3).foregroundStyle(.secondary).padding(.leading, 4)
                        }
                        Text("\(Fmt.bytes(v.used)) used of \(Fmt.bytes(v.total))"
                             + (v.purgeable > 100_000_000 ? " · \(Fmt.bytes(v.purgeable)) more is purgeable" : ""))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let last = model.lastScan {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Scanned \(Fmt.relative(last))").font(.caption).foregroundStyle(.secondary)
                            Text("\(model.progress.files.formatted()) files in \(Int(model.scanDuration)) s").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                CapacityBar(segments: segments, total: v.total)
            }
        }
    }

    private var segments: [CapacitySegment] {
        let v = model.volume
        guard model.root != nil else {
            return [CapacitySegment(id: "used", label: "Used", size: v.used, color: Palette.series[0]),
                    CapacitySegment(id: "free", label: "Free", size: v.available, color: .clear)]
        }
        var segs = StorageCategory.allCases.map {
            CapacitySegment(id: "\($0.rawValue)", label: $0.title, size: model.breakdown[$0] ?? 0, color: $0.color)
        }
        // Everything macOS counts as used that the scan can't see: snapshots, swap, Preboot, protected files.
        let scanned = segs.reduce(0) { $0 + $1.size }
        segs.append(CapacitySegment(id: "hidden", label: "System Data & hidden", size: max(0, v.used - scanned), color: Palette.hidden))
        segs.append(CapacitySegment(id: "free", label: "Free", size: v.available, color: .clear))
        return segs
    }

    private var tiles: some View {
        HStack(spacing: 16) {
            StatTile(title: "Safe to clean", value: model.safeReclaimable, symbol: "checkmark.shield", tint: Palette.good,
                     footnote: model.recommendationsLoading ? "Analyzing…" : "Caches, logs and other things that regenerate")
            StatTile(title: "Worth reviewing", value: model.reviewReclaimable, symbol: "eye", tint: Palette.warning,
                     footnote: "Old downloads, unused apps, dev leftovers")
            StatTile(title: "In the Trash", value: model.trashSize ?? 0, symbol: "trash", tint: Palette.neutral,
                     footnote: model.trashSize == nil ? "Needs Full Disk Access to measure" : "Frees up when emptied")
            StatTile(title: "System Data & hidden", value: model.unaccounted, symbol: "eye.slash", tint: Palette.hidden,
                     footnote: "Swap, snapshots, protected files")
                .onTapGesture { model.section = .hidden }
        }
    }
}

struct HealthBanner: View {
    let volume: VolumeStats
    var body: some View {
        let critical = volume.health == .critical
        let tint = critical ? Palette.critical : Palette.warning
        HStack(spacing: 14) {
            Image(systemName: critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(critical ? "Your disk is critically full" : "Your disk is getting full").font(.headline)
                Text(critical
                     ? "With under 10 GB free, macOS can't install updates, swap gets squeezed and apps may slow down or crash. Aim for at least 20 GB free."
                     : "macOS works best with at least 20 GB free for updates, swap and caches.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

struct FullDiskAccessCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30)).foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Give DiskBro Full Disk Access").font(.headline)
                    Text("macOS hides Mail, Messages, the Trash and some app data from apps by default, so their size can't be counted. Turn on DiskBro under Privacy & Security ▸ Full Disk Access, then rescan.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(spacing: 8) {
                    Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.glassProminent)
                    Button("I've enabled it, rescan") {
                        model.hasFullDiskAccess = Permissions.hasFullDiskAccess()
                        model.startScan()
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

struct TopRecommendationsCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle("Top recommendations")
                if model.recommendationsLoading && model.recommendations.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Analyzing your disk…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if model.recommendations.isEmpty {
                    Text("Nothing obvious to clean. Nice.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    let top = model.recommendations.filter(\.isActionable).sorted { score($0) > score($1) }.prefix(5)
                    ForEach(Array(top)) { rec in
                        HStack(spacing: 12) {
                            Image(systemName: rec.symbol).font(.title3).foregroundStyle(rec.safety.color)
                                .frame(width: 34, height: 34).background(rec.safety.color.opacity(0.12), in: .rect(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.title).font(.callout.weight(.medium)).lineLimit(1)
                                HStack(spacing: 6) {
                                    Image(systemName: rec.safety.symbol).font(.caption2)
                                    Text(rec.safety.label)
                                }.font(.caption).foregroundStyle(rec.safety.color)
                            }
                            Spacer()
                            Text(Fmt.bytes(rec.totalSize)).font(.callout.monospacedDigit().weight(.semibold))
                        }
                        .contentShape(.rect)
                        .onTapGesture { model.section = .cleanup }
                        if rec.id != top.last?.id { Divider() }
                    }
                    Button { model.section = .cleanup } label: {
                        Label("See all recommendations", systemImage: "arrow.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    /// Prefers safe items; a review item needs to be bigger to rank above a safe one.
    private func score(_ r: Recommendation) -> Double {
        Double(r.totalSize) * (r.safety == .safe ? 1.5 : r.safety == .review ? 1 : 0.5)
    }
}

struct BiggestFoldersCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let _ = model.treeVersion
        let home = model.root?.node(atPath: model.home)
        let shared = model.root?.node(atPath: "/Users/Shared")
        let candidates = (home?.children ?? []) + (shared?.children ?? [])
        let items = candidates.filter { !$0.isAggregate }.sorted { $0.size > $1.size }.prefix(8)
        let maxSize = items.first?.size ?? 1
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Biggest folders", detail: "Home & Shared")
                ForEach(Array(items)) { n in
                    Button { model.explore(n) } label: {
                        HStack(spacing: 10) {
                            FileIcon(node: n, size: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(n.displayName).lineLimit(1)
                                    if n.parent === shared {
                                        Text("Shared").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 1).background(Palette.track, in: .capsule)
                                    }
                                    Spacer()
                                    Text(Fmt.bytes(n.size)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                SizeBar(fraction: Double(n.size) / Double(max(maxSize, 1)), tint: Palette.series[0])
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { NodeContextMenu(node: n) }
                }
            }
        }
    }
}
