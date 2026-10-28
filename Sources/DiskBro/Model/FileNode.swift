import Foundation

/// A node in the scanned disk tree. Directories always get a node; files only when they
/// are at least `DiskScanner.keepFileThreshold`. Smaller files are folded into one
/// "aggregate" child per directory to keep memory low on multi-million-file disks.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        static let directory = Flags(rawValue: 1 << 0)
        static let package   = Flags(rawValue: 1 << 1)
        static let aggregate = Flags(rawValue: 1 << 2)
        static let denied    = Flags(rawValue: 1 << 3)
        /// Marks a directory in a refresh result whose existing subtree should be reused.
        static let placeholder = Flags(rawValue: 1 << 4)
    }

    var name: String
    var size: Int64
    var fileCount: Int
    var flags: Flags
    /// Seconds since 1970.
    let modified: Double
    let accessed: Double
    var children: [FileNode] = []
    weak var parent: FileNode?

    init(name: String, size: Int64 = 0, fileCount: Int = 0, flags: Flags, modified: Double = 0, accessed: Double = 0) {
        self.name = name
        self.size = size
        self.fileCount = fileCount
        self.flags = flags
        self.modified = modified
        self.accessed = accessed
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    var isDirectory: Bool { flags.contains(.directory) }
    var isPackage: Bool { flags.contains(.package) }
    var isAggregate: Bool { flags.contains(.aggregate) }
    var isDenied: Bool { flags.contains(.denied) }
    /// True for things that can be opened/trashed as a unit.
    var isRealItem: Bool { !isAggregate }

    var path: String {
        guard let parent else { return name }
        let p = parent.path
        return p == "/" ? "/" + name : p + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String {
        if isAggregate { return "\(fileCount.formatted()) smaller files" }
        if parent == nil { return name == "/" ? "Macintosh HD" : (name as NSString).lastPathComponent }
        return name
    }

    var modifiedDate: Date { Date(timeIntervalSince1970: modified) }
    /// Best guess at when this was last used: the later of access and modification time.
    var lastUsed: Date { Date(timeIntervalSince1970: max(accessed, modified)) }

    var depth: Int {
        var d = 0
        var p = parent
        while let n = p { d += 1; p = n.parent }
        return d
    }

    var ancestors: [FileNode] {
        var result: [FileNode] = []
        var p: FileNode? = self
        while let n = p { result.insert(n, at: 0); p = n.parent }
        return result
    }

    func child(named name: String) -> FileNode? {
        children.first { $0.name == name && !$0.isAggregate }
    }

    /// Looks up an absolute path, assuming `self` is the scan root.
    func node(atPath absolute: String) -> FileNode? {
        let rootPath = name
        guard absolute.hasPrefix(rootPath) else { return nil }
        var rest = String(absolute.dropFirst(rootPath.count))
        if rest.hasPrefix("/") { rest.removeFirst() }
        if rest.isEmpty { return self }
        var current = self
        for comp in rest.split(separator: "/") {
            guard let next = current.child(named: String(comp)) else { return nil }
            current = next
        }
        return current
    }

    func isDescendant(of other: FileNode) -> Bool {
        var p = parent
        while let n = p {
            if n === other { return true }
            p = n.parent
        }
        return false
    }

    /// Removes the node from the tree and subtracts its size from every ancestor.
    func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var p: FileNode? = parent
        while let n = p {
            n.size -= size
            n.fileCount -= fileCount
            p = n.parent
        }
        self.parent = nil
    }

    /// Attaches the node under `newParent`, adding its size to every ancestor.
    func attach(to newParent: FileNode) {
        parent = newParent
        let idx = newParent.children.firstIndex { $0.size < size } ?? newParent.children.endIndex
        newParent.children.insert(self, at: idx)
        var p: FileNode? = newParent
        while let n = p {
            n.size += size
            n.fileCount += fileCount
            p = n.parent
        }
    }

    /// Depth-first walk. Return false from `body` to skip a subtree.
    func walk(_ body: (FileNode) -> Bool) {
        guard body(self) else { return }
        for c in children { c.walk(body) }
    }
}

enum FileKind: String, CaseIterable, Identifiable {
    case all = "All", video = "Video", image = "Images", audio = "Audio", archive = "Archives",
         diskImage = "Disk Images", document = "Documents", app = "Apps", other = "Other"
    var id: String { rawValue }

    static func of(_ name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mts", "braw", "r3d", "prproj": return .video
        case "jpg", "jpeg", "png", "heic", "heif", "raw", "cr2", "cr3", "nef", "arw", "dng", "tif", "tiff", "psd", "gif", "webp", "bmp", "svg", "afphoto", "sketch", "fig": return .image
        case "mp3", "wav", "aiff", "aif", "flac", "m4a", "aac", "ogg", "logicx", "band": return .audio
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "xip": return .archive
        case "dmg", "iso", "img", "pkg", "mpkg", "sparseimage", "sparsebundle", "vmdk", "qcow2", "raw.img", "vdi", "ipsw": return .diskImage
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "md", "csv", "json", "epub": return .document
        case "app": return .app
        default: return .other
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .diskImage: "externaldrive"
        case .document: "doc.text"
        case .app: "app.dashed"
        case .other: "doc"
        }
    }
}
