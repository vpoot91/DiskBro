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
            let v = VolumeStats.current()
            print("volume: used \(Fmt.bytes(v.used)) free \(Fmt.bytes(v.available)) purgeable \(Fmt.bytes(v.purgeable))")
            for (cat, size) in CategoryBreakdown.compute(root: root).sorted(by: { $0.value > $1.value }) {
                print("  \(cat.title): \(Fmt.bytes(size))")
            }
            let t = Date()
            let recs = await RecommendationEngine(root: root).build()
            print("recommendations (\(String(format: "%.1f", Date().timeIntervalSince(t)))s):")
            for r in recs { print("  [\(r.safety.label)] \(r.title): \(Fmt.bytes(r.totalSize)) (\(r.entries.count) items)") }
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
