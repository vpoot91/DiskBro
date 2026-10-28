import Foundation
import CryptoKit
import os

struct DuplicateGroup: Identifiable, @unchecked Sendable {
    let id: String
    let size: Int64
    var files: [FileNode]
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

struct DuplicateProgress: Sendable {
    var phase = "Collecting files"
    var done = 0
    var total = 0
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Finds identical files by size → partial hash (head + tail) → full SHA-256.
final class DuplicateFinder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (DuplicateProgress(), false))
    var progress: DuplicateProgress { lock.withLock { $0.0 } }
    func cancel() { lock.withLock { $0.1 = true } }
    private var cancelled: Bool { lock.withLock { $0.1 } }
    private func set(_ f: (inout DuplicateProgress) -> Void) { lock.withLock { f(&$0.0) } }

    func find(root: FileNode, minSize: Int64) async -> [DuplicateGroup] {
        let home = NSHomeDirectory()
        // Only look at user files; app bundles and Library data legitimately contain identical files.
        let skipNames: Set<String> = ["node_modules", ".git", ".Trash", "Library", ".npm", ".cargo", ".gradle", ".venv", "DerivedData"]
        var bySize: [Int64: [FileNode]] = [:]
        for base in [home] {
            root.node(atPath: base)?.walk { n in
                if n.isDirectory { return !n.isPackage && !skipNames.contains(n.name) }
                if !n.isAggregate && n.size >= minSize { bySize[n.size, default: []].append(n) }
                return false
            }
        }
        var candidates = bySize.values.filter { $0.count > 1 }
        set { $0.phase = "Comparing file starts"; $0.done = 0; $0.total = candidates.reduce(0) { $0 + $1.count } }

        // Stage 2: partial hash.
        var stage2: [[FileNode]] = []
        for group in candidates {
            if cancelled { return [] }
            var byHash: [String: [FileNode]] = [:]
            for f in group {
                if let h = hash(path: f.path, partial: true) { byHash[h, default: []].append(f) }
                set { $0.done += 1 }
            }
            stage2 += byHash.values.filter { $0.count > 1 }
        }
        candidates = stage2

        // Stage 3: full hash.
        set { $0.phase = "Verifying contents"; $0.done = 0; $0.total = candidates.reduce(0) { $0 + $1.count } }
        var result: [DuplicateGroup] = []
        for group in candidates {
            if cancelled { return [] }
            var byHash: [String: [FileNode]] = [:]
            for f in group {
                if let h = hash(path: f.path, partial: false) { byHash[h, default: []].append(f) }
                set { $0.done += 1 }
            }
            for (h, files) in byHash where files.count > 1 {
                // Keep the oldest copy first, so it's the default "keep".
                let sorted = files.sorted { ($0.modified, $0.path.count) < ($1.modified, $1.path.count) }
                result.append(DuplicateGroup(id: h, size: files[0].size, files: sorted))
            }
        }
        return result.sorted { $0.wasted > $1.wasted }
    }

    private func hash(path: String, partial: Bool) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 1 << 20
        if partial {
            let edge = 64 * 1024
            if let head = try? handle.read(upToCount: edge) { hasher.update(data: head) }
            if let end = try? handle.seekToEnd(), end > UInt64(edge * 2) {
                try? handle.seek(toOffset: end - UInt64(edge))
                if let tail = try? handle.read(upToCount: edge) { hasher.update(data: tail) }
            }
        } else {
            while true {
                if cancelled { return nil }
                guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
