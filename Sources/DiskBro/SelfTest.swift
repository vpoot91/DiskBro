import Foundation

/// `DiskBro --selftest` runs the scanner and recommendation engine headless and prints a report.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let start = Date()
            let scanner = DiskScanner(rootPath: "/")
            let root = await scanner.scan()
            let p = scanner.progress
            print("scan: \(p.files) files, \(p.directories) dirs, \(Fmt.bytes(root.size)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s, denied \(scanner.deniedCount)")
            if CommandLine.arguments.contains("--cache") {
                func count(_ n: FileNode) -> Int { n.children.reduce(1) { $0 + count($1) } }
                var t = Date()
                TreeCache.save(root: root, meta: .init(eventId: ChangeTracker.currentEventId, scanDate: .now, scanDuration: 0, deniedCount: 0, deniedPaths: []))
                let size = (try? FileManager.default.attributesOfItem(atPath: TreeCache.url.path)[.size] as? Int) ?? 0
                print("cache save: \(String(format: "%.2f", Date().timeIntervalSince(t)))s, \(Fmt.bytes(Int64(size)))")
                t = Date()
                let loaded = TreeCache.load(rootPath: "/")
                print("cache load: \(String(format: "%.2f", Date().timeIntervalSince(t)))s, nodes \(loaded.map { count($0.0) } ?? -1) vs \(count(root)), size match \(loaded?.0.size == root.size)")
                // Incremental refresh of the home folder: must match a fresh read.
                if let (tree, _) = loaded, let home = tree.node(atPath: NSHomeDirectory()) {
                    t = Date()
                    let probe = DiskScanner(rootPath: "/")
                    let fresh = probe.refreshDirectory(path: home.path, name: home.name, knownSubdirs: Set(home.children.filter(\.isDirectory).map(\.name)), recursive: false)
                    print("shallow refresh of home: \(String(format: "%.3f", Date().timeIntervalSince(t)))s, \(fresh.children.count) entries, placeholders \(fresh.children.filter { $0.flags.contains(.placeholder) }.count)")
                }
            }
            let v = VolumeStats.current()
            print("volume: used \(Fmt.bytes(v.used)) free \(Fmt.bytes(v.available)) purgeable \(Fmt.bytes(v.purgeable))")
            for (cat, size) in CategoryBreakdown.compute(root: root).sorted(by: { $0.value > $1.value }) {
                print("  \(cat.title): \(Fmt.bytes(size))")
            }
            let t = Date()
            let recs = await RecommendationEngine(root: root).build()
            print("recommendations (\(String(format: "%.1f", Date().timeIntervalSince(t)))s):")
            for r in recs {
                print("  [\(r.safety.label)] \(r.title): \(Fmt.bytes(r.totalSize)) (\(r.entries.count) items)")
                if CommandLine.arguments.contains("--verbose") {
                    for e in r.entries.prefix(30) { print("      \(e.name) · \(Fmt.bytes(e.size)) · \(e.detail ?? "")") }
                }
            }
            print("root top:")
            for c in root.children.prefix(15) { print("  \(c.displayName): \(Fmt.bytes(c.size))") }
            if let home = root.node(atPath: NSHomeDirectory()) {
                print("home top:")
                for c in home.children.prefix(12) { print("  \(c.displayName): \(Fmt.bytes(c.size))") }
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
