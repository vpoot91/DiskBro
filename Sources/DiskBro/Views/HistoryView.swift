import SwiftUI
import Charts

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var range: Range = .month
    @State private var hoverDate: Date?

    enum Range: String, CaseIterable, Identifiable {
        case day = "24 Hours", week = "7 Days", month = "30 Days", all = "All"
        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            case .all: nil
            }
        }
    }

    var body: some View {
        let _ = model.historyVersion
        let all = model.history.entries
        let points = range.seconds.map { s in all.filter { Date.now.timeIntervalSince($0.date) <= s } } ?? all
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader("History", subtitle: "Free space over time, sampled while DiskBro is open and on every scan.") {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 320).labelsHidden()
                }

                HStack(spacing: 16) {
                    trendTiles(points)
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle("Free space", detail: points.count < 2 ? "Collecting data…" : nil)
                        if points.count < 2 {
                            Text("Come back later. DiskBro needs a few samples to draw a trend.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            chart(points)
                        }
                    }
                }

                ChangesCard()
            }
            .padding(28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    private func chart(_ points: [HistoryEntry]) -> some View {
        let hovered = hoverDate.flatMap { d in points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } }
        let gb: (Int64) -> Double = { Double($0) / 1e9 }
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Date", p.date), y: .value("Free (GB)", gb(p.free)))
                    .foregroundStyle(LinearGradient(colors: [Palette.series[0].opacity(0.25), Palette.series[0].opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", p.date), y: .value("Free (GB)", gb(p.free)))
                    .foregroundStyle(Palette.series[0])
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            ForEach(points.filter(\.isScan)) { p in
                PointMark(x: .value("Date", p.date), y: .value("Free (GB)", gb(p.free)))
                    .foregroundStyle(Palette.series[0])
                    .symbolSize(40)
            }
            RuleMark(y: .value("Critical", 10))
                .foregroundStyle(Palette.critical.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("10 GB critical").font(.caption2).foregroundStyle(.secondary)
                }
            if let h = hovered {
                RuleMark(x: .value("Date", h.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.bytes(h.free) + " free").font(.callout.weight(.semibold)).monospacedDigit()
                            Text(h.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                PointMark(x: .value("Date", h.date), y: .value("Free (GB)", gb(h.free)))
                    .foregroundStyle(Palette.series[0]).symbolSize(70)
            }
        }
        .chartYAxisLabel("GB free")
        .chartYScale(domain: 0...max(12, (points.map { gb($0.free) }.max() ?? 10) * 1.15))
        .chartXSelection(value: $hoverDate)
        .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.secondary.opacity(0.15)); AxisValueLabel() } }
        .frame(height: 280)
    }

    @ViewBuilder
    private func trendTiles(_ points: [HistoryEntry]) -> some View {
        let first = points.first, last = points.last
        let delta = (last?.free ?? 0) - (first?.free ?? 0)
        let span = (last?.date.timeIntervalSince(first?.date ?? .now) ?? 0) / 86_400
        let perDay = span >= 0.5 ? Double(delta) / span : 0
        StatTile(title: "Change in period", value: abs(delta), symbol: delta >= 0 ? "arrow.up.right" : "arrow.down.right",
                 tint: delta >= 0 ? Palette.good : Palette.critical,
                 footnote: delta >= 0 ? "More free space than at the start" : "Less free space than at the start")
        StatTile(title: "Average per day", value: Int64(abs(perDay)), symbol: "calendar",
                 tint: perDay >= 0 ? Palette.good : Palette.warning,
                 footnote: span < 0.5 ? "Needs at least half a day of data" : (perDay >= 0 ? "Freed per day" : "Consumed per day"))
        let runway: String = {
            guard perDay < -50_000_000 else { return "Stable. No sign of running out." }
            let days = Double(model.volume.available) / -perDay
            return days < 1 ? "Full within a day at this rate" : "Full in about \(Int(days)) days at this rate"
        }()
        StatTile(title: "Free now", value: model.volume.available, symbol: "internaldrive", tint: Palette.series[0], footnote: runway)
    }
}

struct ChangesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.historyVersion
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if let (since, changes) = model.history.changesSincePreviousScan() {
                    SectionTitle("What changed since the previous scan", detail: "Compared with \(Fmt.relative(since))")
                    if changes.isEmpty {
                        Text("No folder changed by more than 50 MB.").foregroundStyle(.secondary)
                    } else {
                        let maxDelta = max(changes.map { abs($0.delta) }.max() ?? 1, 1)
                        ForEach(changes) { c in
                            HStack(spacing: 10) {
                                Image(systemName: c.delta > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(c.delta > 0 ? Palette.critical : Palette.good)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(Fmt.tildePath(c.path)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(Fmt.signedBytes(c.delta)).monospacedDigit()
                                            .foregroundStyle(c.delta > 0 ? Palette.critical : Palette.good)
                                    }
                                    SizeBar(fraction: Double(abs(c.delta)) / Double(maxDelta), tint: (c.delta > 0 ? Palette.critical : Palette.good).opacity(0.6))
                                }
                                Button { model.reveal(URL(fileURLWithPath: c.path)) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless)
                            }
                            .contextMenu {
                                Button("Reveal in Finder") { model.reveal(URL(fileURLWithPath: c.path)) }
                                if let n = model.root?.node(atPath: c.path) { Button("Explore") { model.explore(n) } }
                            }
                        }
                    }
                } else {
                    SectionTitle("What changed since the previous scan")
                    Text("After your next scan, DiskBro shows which folders grew or shrank since this one.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
