import Foundation

struct HistoryEntry: Codable, Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let total: Int64
    let free: Int64
    let freeWithPurgeable: Int64
    var scanned: Int64?
    /// Folder sizes (path → bytes) captured at scan time, used for "what changed".
    var folders: [String: Int64]?

    var isScan: Bool { folders != nil }
}

struct FolderChange: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let before: Int64
    let after: Int64
    var delta: Int64 { after - before }
}

@MainActor
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DiskBro")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    /// Records a free-space sample, skipping ones that add nothing to the chart.
    func sample(_ v: VolumeStats) {
        if let last = entries.last, Date.now.timeIntervalSince(last.date) < 20 * 60, abs(last.free - v.available) < 200_000_000 { return }
        entries.append(HistoryEntry(date: .now, total: v.total, free: v.available, freeWithPurgeable: v.availableForImportant))
        save()
    }

    func recordScan(_ v: VolumeStats, scanned: Int64, folders: [String: Int64]) {
        entries.append(HistoryEntry(date: .now, total: v.total, free: v.available, freeWithPurgeable: v.availableForImportant,
                                    scanned: scanned, folders: folders))
        // Keep folder maps only for the latest 12 scans to bound file size.
        let scanIdx = entries.indices.filter { entries[$0].folders != nil }
        for i in scanIdx.dropLast(12) { entries[i].folders = nil }
        if entries.count > 5000 { entries.removeFirst(entries.count - 5000) }
        save()
    }

    var scans: [HistoryEntry] { entries.filter(\.isScan) }

    /// Folders that changed between the two most recent scans, reduced to the deepest folder that explains each change.
    func changesSincePreviousScan(minDelta: Int64 = 50_000_000) -> (since: Date, changes: [FolderChange])? {
        let s = scans
        guard s.count >= 2, let a = s[s.count - 2].folders, let b = s[s.count - 1].folders else { return nil }
        var changes: [FolderChange] = []
        for path in Set(a.keys).union(b.keys) {
            let c = FolderChange(path: path, before: a[path] ?? 0, after: b[path] ?? 0)
            if abs(c.delta) >= minDelta { changes.append(c) }
        }
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        let explained = changes.filter { parent in
            byPath.values.contains { child in
                child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/") && child.path != parent.path
                    && (child.delta > 0) == (parent.delta > 0) && abs(child.delta) >= abs(parent.delta) * 7 / 10
            }
        }.map(\.path)
        let explainedSet = Set(explained)
        let result = changes.filter { !explainedSet.contains($0.path) }.sorted { abs($0.delta) > abs($1.delta) }
        return (s[s.count - 2].date, Array(result.prefix(25)))
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    nonisolated static func folderMap(root: FileNode, maxDepth: Int = 5, minSize: Int64 = 50_000_000) -> [String: Int64] {
        var map: [String: Int64] = [:]
        func visit(_ n: FileNode, path: String, depth: Int) {
            map[path] = n.size
            guard depth < maxDepth else { return }
            for c in n.children where c.isDirectory && c.size >= minSize {
                visit(c, path: path == "/" ? "/" + c.name : path + "/" + c.name, depth: depth + 1)
            }
        }
        visit(root, path: root.name, depth: 0)
        return map
    }
}
