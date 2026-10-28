import Foundation

/// Persists the scanned tree in a compact binary format so launches don't need a full scan.
/// The stored FSEvents id marks the point the tree is accurate up to; replaying the journal from
/// there brings it current.
enum TreeCache {
    struct Meta {
        var eventId: UInt64
        var scanDate: Date
        var scanDuration: Double
        var deniedCount: Int
        var deniedPaths: [String]
    }

    private static let magic: UInt32 = 0x4442_4331 // "DBC1"
    private static let version: UInt32 = 1

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskBro/tree.cache")
    }

    static func save(root: FileNode, meta: Meta) {
        var w = Writer()
        w.reserve(64 << 20)
        w.u32(magic); w.u32(version)
        w.u64(meta.eventId)
        w.f64(meta.scanDate.timeIntervalSince1970)
        w.f64(meta.scanDuration)
        w.u32(UInt32(meta.deniedCount))
        w.u32(UInt32(meta.deniedPaths.count))
        meta.deniedPaths.forEach { w.string($0) }

        func write(_ n: FileNode) {
            w.string(n.name)
            w.u8(n.flags.subtracting(.placeholder).rawValue)
            w.i64(n.size)
            w.u32(UInt32(clamping: n.fileCount))
            w.i64(Int64(n.modified))
            w.i64(Int64(n.accessed))
            w.u32(UInt32(n.children.count))
            for c in n.children { write(c) }
        }
        write(root)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(w.bytes).write(to: url, options: .atomic)
    }

    static func load(rootPath: String) -> (FileNode, Meta)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { raw -> (FileNode, Meta)? in
            var r = Reader(buf: raw)
            guard r.u32() == magic, r.u32() == version else { return nil }
            let eventId = r.u64()
            let date = Date(timeIntervalSince1970: r.f64())
            let duration = r.f64()
            let deniedCount = Int(r.u32())
            let deniedPaths = (0..<Int(r.u32())).map { _ in r.string() }
            guard r.ok else { return nil }

            func read() -> FileNode? {
                let name = r.string()
                let flags = FileNode.Flags(rawValue: r.u8())
                let size = r.i64()
                let count = Int(r.u32())
                let modified = Double(r.i64())
                let accessed = Double(r.i64())
                let childCount = Int(r.u32())
                guard r.ok else { return nil }
                let n = FileNode(name: name, size: size, fileCount: count, flags: flags, modified: modified, accessed: accessed)
                n.children.reserveCapacity(childCount)
                for _ in 0..<childCount {
                    guard let c = read() else { return nil }
                    c.parent = n
                    n.children.append(c)
                }
                return n
            }
            guard let root = read(), root.name == rootPath else { return nil }
            return (root, Meta(eventId: eventId, scanDate: date, scanDuration: duration, deniedCount: deniedCount, deniedPaths: deniedPaths))
        }
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }

    // MARK: - Binary helpers

    private struct Writer {
        var bytes: [UInt8] = []
        mutating func reserve(_ n: Int) { bytes.reserveCapacity(n) }
        mutating func raw<T>(_ v: T) { withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) } }
        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u32(_ v: UInt32) { raw(v.littleEndian) }
        mutating func u64(_ v: UInt64) { raw(v.littleEndian) }
        mutating func i64(_ v: Int64) { raw(v.littleEndian) }
        mutating func f64(_ v: Double) { raw(v.bitPattern.littleEndian) }
        mutating func string(_ s: String) {
            var s = s
            s.withUTF8 { utf8 in
                let len = min(utf8.count, Int(UInt16.max))
                raw(UInt16(len).littleEndian)
                bytes.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[0..<len]))
            }
        }
    }

    private struct Reader {
        let buf: UnsafeRawBufferPointer
        var pos = 0
        var ok = true

        init(buf: UnsafeRawBufferPointer) { self.buf = buf }

        mutating func take<T: FixedWidthInteger>(_: T.Type) -> T {
            let size = MemoryLayout<T>.size
            guard ok, pos + size <= buf.count else { ok = false; return 0 }
            let v = buf.loadUnaligned(fromByteOffset: pos, as: T.self)
            pos += size
            return T(littleEndian: v)
        }
        mutating func u8() -> UInt8 { take(UInt8.self) }
        mutating func u32() -> UInt32 { take(UInt32.self) }
        mutating func u64() -> UInt64 { take(UInt64.self) }
        mutating func i64() -> Int64 { take(Int64.self) }
        mutating func f64() -> Double { Double(bitPattern: take(UInt64.self)) }
        mutating func string() -> String {
            let len = Int(take(UInt16.self))
            guard ok, pos + len <= buf.count else { ok = false; return "" }
            let s = String(decoding: UnsafeRawBufferPointer(rebasing: buf[pos..<pos + len]), as: UTF8.self)
            pos += len
            return s
        }
    }
}
