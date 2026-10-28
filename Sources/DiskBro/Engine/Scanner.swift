import Foundation
import Darwin
import os

struct ScanProgress: Sendable {
    var files = 0
    var directories = 0
    var bytes: Int64 = 0
    var currentPath = ""
}

/// Parallel POSIX walker. Uses `readdir` + `fstatat` (no URL resource values), counts
/// allocated blocks so sparse and iCloud-evicted files report their real footprint,
/// counts hard links once, and never crosses into other volumes.
final class DiskScanner: @unchecked Sendable {
    static let keepFileThreshold: Int64 = 1 << 20

    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "xcarchive",
        "plugin", "kext", "appex", "xpc", "pkg", "sparsebundle", "fcpbundle", "logicx", "imovielibrary",
        "photolibrary", "aplibrary", "lrlibrary", "dSYM", "xcodeproj", "xcworkspace", "playground", "simruntime",
    ]

    private struct State {
        var progress = ScanProgress()
        var denied: [String] = []
        var deniedCount = 0
        var seenInodes = Set<UInt64>()
        var cancelled = false
    }

    let rootPath: String
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let allowedDevices: Set<Int32>
    private let skipPaths: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/.vol", "/.nofollow", "/.resolve",
        "/private/var/vm", "/Network",
    ]

    init(rootPath: String) {
        self.rootPath = rootPath
        // Never let a scan trigger iCloud/File Provider downloads of evicted ("dataless") items;
        // reading such a directory would otherwise block until it's fetched from the network.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        var devs = Set<Int32>()
        for p in ["/", "/System/Volumes/Data", rootPath] {
            var st = stat()
            if lstat(p, &st) == 0 { devs.insert(st.st_dev) }
        }
        allowedDevices = devs
    }

    var progress: ScanProgress { lock.withLock { $0.progress } }
    var deniedPaths: [String] { lock.withLock { $0.denied } }
    var deniedCount: Int { lock.withLock { $0.deniedCount } }
    func cancel() { lock.withLock { $0.cancelled = true } }
    private var isCancelled: Bool { lock.withLock { $0.cancelled } }

    func scan() async -> FileNode {
        let root = FileNode(name: rootPath, flags: [.directory])
        await scanDirectory(root, path: rootPath, depth: 0)
        return root
    }

    private func scanDirectory(_ node: FileNode, path: String, depth: Int) async {
        let subdirs = readDirectory(node, path: path)
        if depth < 7 && subdirs.count > 0 {
            await withTaskGroup(of: Void.self) { group in
                for (child, childPath) in subdirs {
                    group.addTask { await self.scanDirectory(child, path: childPath, depth: depth + 1) }
                }
            }
        } else {
            for (child, childPath) in subdirs { scanSync(child, path: childPath) }
        }
        finalize(node)
    }

    private func scanSync(_ node: FileNode, path: String) {
        let subdirs = readDirectory(node, path: path)
        for (child, childPath) in subdirs { scanSync(child, path: childPath) }
        finalize(node)
    }

    private func finalize(_ node: FileNode) {
        var size: Int64 = 0
        var count = 0
        for c in node.children {
            size += c.size
            count += c.isDirectory ? c.fileCount : (c.isAggregate ? c.fileCount : 1)
        }
        node.size = size
        node.fileCount = count
        node.children.sort { $0.size > $1.size }
    }

    private func readDirectory(_ node: FileNode, path: String) -> [(FileNode, String)] {
        if isCancelled { return [] }
        guard let dir = opendir(path) else {
            let err = errno
            if err == EACCES || err == EPERM {
                node.flags.insert(.denied)
                lock.withLock {
                    $0.deniedCount += 1
                    if $0.denied.count < 500 { $0.denied.append(path) }
                }
            }
            return []
        }
        defer { closedir(dir) }
        let fd = dirfd(dir)

        var subdirs: [(FileNode, String)] = []
        var smallSize: Int64 = 0
        var smallCount = 0
        var smallModified: Double = 0
        var fileTotal = 0
        var byteTotal: Int64 = 0

        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: &ent.pointee.d_name) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }

            var st = stat()
            if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { continue }
            let type = st.st_mode & S_IFMT
            let childPath = path == "/" ? "/" + name : path + "/" + name
            let mtime = Double(st.st_mtimespec.tv_sec)
            let atime = Double(st.st_atimespec.tv_sec)

            if type == S_IFDIR {
                if skipPaths.contains(childPath) || !allowedDevices.contains(st.st_dev) { continue }
                // Evicted iCloud folder: contents live only in the cloud and take no local space.
                if st.st_flags & UInt32(SF_DATALESS) != 0 { continue }
                var flags: FileNode.Flags = [.directory]
                let ext = (name as NSString).pathExtension
                if !ext.isEmpty && Self.packageExtensions.contains(ext) { flags.insert(.package) }
                let child = FileNode(name: name, flags: flags, modified: mtime, accessed: atime)
                child.parent = node
                node.children.append(child)
                subdirs.append((child, childPath))
            } else {
                var allocated = Int64(st.st_blocks) * 512
                if type == S_IFREG && st.st_nlink > 1 {
                    let key = (UInt64(UInt32(bitPattern: st.st_dev)) << 40) ^ st.st_ino
                    let first = lock.withLock { $0.seenInodes.insert(key).inserted }
                    if !first { allocated = 0 }
                }
                fileTotal += 1
                byteTotal += allocated
                if type == S_IFREG && allocated >= Self.keepFileThreshold {
                    let child = FileNode(name: name, size: allocated, fileCount: 1, flags: [], modified: mtime, accessed: atime)
                    child.parent = node
                    node.children.append(child)
                } else {
                    smallSize += allocated
                    smallCount += 1
                    smallModified = max(smallModified, mtime)
                }
            }
        }

        if smallCount > 0 {
            let agg = FileNode(name: "·small", size: smallSize, fileCount: smallCount, flags: [.aggregate], modified: smallModified, accessed: smallModified)
            agg.parent = node
            node.children.append(agg)
        }

        let (files, bytes) = (fileTotal, byteTotal)
        lock.withLock {
            $0.progress.files += files
            $0.progress.directories += 1
            $0.progress.bytes += bytes
            $0.progress.currentPath = path
        }
        return subdirs
    }
}
