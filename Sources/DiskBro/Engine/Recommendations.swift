import SwiftUI
import CoreServices

enum Safety: Int, Comparable, Sendable {
    case safe, review, careful
    static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .careful: "Careful"
        }
    }
    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .careful: "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch self {
        case .safe: Palette.good
        case .review: Palette.warning
        case .careful: Palette.critical
        }
    }
    var hint: String {
        switch self {
        case .safe: "Regenerated automatically. Nothing of yours is lost."
        case .review: "Probably not needed, but check before removing."
        case .careful: "May contain things you can't get back."
        }
    }
}

enum RecommendationGroup: Int, CaseIterable, Sendable {
    case quickWins, developer, files, apps, system
    var title: String {
        switch self {
        case .quickWins: "Quick wins"
        case .developer: "Developer"
        case .files: "Your files"
        case .apps: "Applications"
        case .system: "System & backups"
        }
    }
}

struct CleanupEntry: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let name: String
    let detail: String?
    let size: Int64
    let url: URL
    var node: FileNode?
    var lastUsed: Date?
    var preselected: Bool = true
    /// Argument appended to a per-entry command (e.g. a runtime identifier).
    var commandArgument: String?

    static func == (a: CleanupEntry, b: CleanupEntry) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum CleanupAction: Sendable {
    case trash
    case emptyTrash
    /// Runs `executable args...`; if `perEntry`, once per selected entry with its `commandArgument` appended.
    case command(executable: String, args: [String], perEntry: Bool, admin: Bool)
    /// Nothing to delete automatically; offer guidance and an optional place to open.
    case guidance(openTitle: String, open: URL?)
}

struct Recommendation: Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    let safety: Safety
    let group: RecommendationGroup
    var entries: [CleanupEntry]
    let action: CleanupAction
    /// For commands where the reclaimable size is known but isn't the sum of entries.
    var sizeOverride: Int64? = nil

    var totalSize: Int64 { sizeOverride ?? entries.reduce(0) { $0 + $1.size } }
    var isActionable: Bool { if case .guidance = action { false } else { true } }
}

/// Builds cleanup recommendations by looking at known locations in the scanned tree.
struct RecommendationEngine: @unchecked Sendable {
    let root: FileNode
    let home = NSHomeDirectory()
    let fm = FileManager.default

    private let MB: Int64 = 1 << 20
    private let GB: Int64 = 1 << 30

    func node(_ path: String) -> FileNode? { root.node(atPath: path) }

    func entry(_ n: FileNode, name: String? = nil, detail: String? = nil, preselected: Bool = true) -> CleanupEntry {
        CleanupEntry(id: n.path, name: name ?? n.displayName, detail: detail, size: n.size, url: n.url,
                     node: n, lastUsed: n.lastUsed, preselected: preselected)
    }

    func childEntries(_ path: String, minSize: Int64, preselected: Bool = true) -> [CleanupEntry] {
        guard let n = node(path) else { return [] }
        return n.children.filter { !$0.isAggregate && $0.size >= minSize }.map { entry($0, preselected: preselected) }
    }

    func daysAgo(_ d: Date) -> Int { Int(Date.now.timeIntervalSince(d) / 86_400) }

    func build() async -> [Recommendation] {
        var recs: [Recommendation] = []
        func add(_ r: Recommendation, min: Int64) { if r.totalSize >= min { recs.append(r) } }

        // MARK: Quick wins

        if let trash = node(home + "/.Trash") {
            add(Recommendation(id: "trash", title: "Empty the Trash",
                               summary: "Items in the Trash still take up space until it's emptied.",
                               symbol: "trash", safety: .safe, group: .quickWins,
                               entries: trash.children.filter { !$0.isAggregate }.map { entry($0) }
                                   + trash.children.filter(\.isAggregate).map { entry($0, name: "Other small items") },
                               action: .emptyTrash), min: MB)
        }

        let cachesPath = home + "/Library/Caches"
        add(Recommendation(id: "caches", title: "App caches",
                           summary: "Temporary data apps keep to load faster. Apps rebuild what they need. Quit big apps first for the best result.",
                           symbol: "internaldrive", safety: .safe, group: .quickWins,
                           entries: childEntries(cachesPath, minSize: 2 * MB), action: .trash), min: 20 * MB)

        if let containers = node(home + "/Library/Containers") {
            var entries: [CleanupEntry] = []
            for c in containers.children where c.isDirectory {
                if let caches = c.child(named: "Data")?.child(named: "Library")?.child(named: "Caches"), caches.size >= 5 * MB {
                    entries.append(entry(caches, name: c.name, detail: "Sandboxed app cache"))
                }
            }
            add(Recommendation(id: "sandbox-caches", title: "Sandboxed app caches",
                               summary: "Caches of App Store and sandboxed apps, stored inside their containers.",
                               symbol: "square.stack.3d.up", safety: .safe, group: .quickWins,
                               entries: entries.sorted { $0.size > $1.size }, action: .trash), min: 20 * MB)
        }

        var logs = childEntries(home + "/Library/Logs", minSize: 1 * MB)
        logs += childEntries(home + "/Library/Application Support/CrashReporter", minSize: 1 * MB)
        add(Recommendation(id: "logs", title: "Logs & crash reports",
                           summary: "Diagnostic logs written by apps and macOS. Only useful when you're troubleshooting.",
                           symbol: "list.bullet.rectangle", safety: .safe, group: .quickWins,
                           entries: logs, action: .trash), min: 10 * MB)

        var mailDownloads: [CleanupEntry] = []
        if let n = node(home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads") { mailDownloads.append(entry(n, name: "Mail Downloads")) }
        add(Recommendation(id: "mail-downloads", title: "Opened Mail attachments",
                           summary: "Copies of attachments you opened from Mail. The originals stay in your mailbox.",
                           symbol: "paperclip", safety: .safe, group: .quickWins,
                           entries: mailDownloads, action: .trash), min: 20 * MB)

        var installers: [CleanupEntry] = []
        let installerKinds: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "ipsw"]
        for base in [home + "/Downloads", home + "/Desktop"] {
            node(base)?.walk { n in
                if n.isPackage && (n.name as NSString).pathExtension != "pkg" { return false }
                if !n.isAggregate && installerKinds.contains((n.name as NSString).pathExtension.lowercased()) {
                    installers.append(entry(n, detail: Fmt.tildePath((n.parent?.path ?? "")) + " · " + Fmt.age(n.lastUsed)))
                    return false
                }
                return true
            }
        }
        if let ipsw = node(home + "/Library/iTunes/iPhone Software Updates") { installers += ipsw.children.filter { !$0.isAggregate }.map { entry($0, detail: "iPhone software update") } }
        add(Recommendation(id: "installers", title: "Installers & disk images",
                           summary: "DMG, PKG and IPSW files you've usually installed already and can download again.",
                           symbol: "externaldrive.badge.minus", safety: .safe, group: .quickWins,
                           entries: installers.sorted { $0.size > $1.size }, action: .trash), min: 20 * MB)

        // MARK: Developer

        let dev = home + "/Library/Developer"
        var derived: [CleanupEntry] = []
        if let n = node(dev + "/Xcode/DerivedData") { derived = n.children.filter { !$0.isAggregate }.map { entry($0, detail: "Last built " + Fmt.age($0.lastUsed)) } }
        add(Recommendation(id: "derived-data", title: "Xcode DerivedData",
                           summary: "Build products and indexes. Xcode rebuilds them on the next build.",
                           symbol: "hammer", safety: .safe, group: .developer,
                           entries: derived.sorted { $0.size > $1.size }, action: .trash), min: 20 * MB)

        var support: [CleanupEntry] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "xrOS"] {
            support += childEntries(dev + "/Xcode/\(platform) DeviceSupport", minSize: 10 * MB).map {
                var e = $0; e = CleanupEntry(id: e.id, name: "\(platform) \(e.name)", detail: "Used " + Fmt.age(e.lastUsed ?? .now), size: e.size, url: e.url, node: e.node, lastUsed: e.lastUsed); return e
            }
        }
        add(Recommendation(id: "device-support", title: "Device support files",
                           summary: "Debug symbols copied from devices you connected. Xcode copies them again when needed.",
                           symbol: "iphone.gen3", safety: .safe, group: .developer,
                           entries: support.sorted { $0.size > $1.size }, action: .trash), min: 20 * MB)

        var simCaches: [CleanupEntry] = []
        if let n = node(dev + "/CoreSimulator/Caches") { simCaches.append(entry(n, name: "Simulator caches")) }
        if let n = node(dev + "/XCTestDevices") { simCaches.append(entry(n, name: "XCTest clone devices")) }
        if let n = node(dev + "/Xcode/UserData/Previews") { simCaches.append(entry(n, name: "SwiftUI preview simulators")) }
        if let n = node(dev + "/DVTDownloads") { simCaches.append(entry(n, name: "Xcode downloads")) }
        add(Recommendation(id: "sim-caches", title: "Simulator & preview caches",
                           summary: "Dyld caches, preview devices and test clones. All regenerated on demand.",
                           symbol: "ipad.and.iphone", safety: .safe, group: .developer,
                           entries: simCaches, action: .trash), min: 20 * MB)

        if FileManager.default.fileExists(atPath: "/usr/bin/xcrun") {
            recs += await simulatorRecommendations()
        }

        add(Recommendation(id: "archives", title: "Xcode archives",
                           summary: "Builds you archived for distribution. Keep the ones you might need to symbolicate crash logs for.",
                           symbol: "archivebox", safety: .review, group: .developer,
                           entries: childEntries(dev + "/Xcode/Archives", minSize: 1 * MB, preselected: false), action: .trash), min: 50 * MB)

        var pkgCaches: [CleanupEntry] = []
        let pkgCachePaths: [(String, String)] = [
            (home + "/.npm/_cacache", "npm cache"), (home + "/Library/pnpm/store", "pnpm store"),
            (home + "/.bun/install/cache", "Bun cache"), (home + "/.gradle/caches", "Gradle caches"),
            (home + "/.cargo/registry/cache", "Cargo registry cache"), (home + "/go/pkg/mod/cache", "Go module cache"),
            (home + "/.yarn/berry/cache", "Yarn cache"), (home + "/.cocoapods/repos", "CocoaPods specs"),
            (home + "/.pub-cache", "Dart/Flutter pub cache"), (home + "/.nuget/packages", "NuGet packages"),
            (home + "/.composer/cache", "Composer cache"), (home + "/.cache/pip", "pip cache"), (home + "/.cache/uv", "uv cache"),
            (home + "/.android/cache", "Android cache"),
        ]
        for (p, label) in pkgCachePaths { if let n = node(p), n.size >= 5 * MB { pkgCaches.append(entry(n, name: label, detail: Fmt.tildePath(p))) } }
        add(Recommendation(id: "pkg-caches", title: "Package manager caches",
                           summary: "Downloaded packages kept for faster installs. They're re-downloaded when needed.",
                           symbol: "shippingbox", safety: .safe, group: .developer,
                           entries: pkgCaches.sorted { $0.size > $1.size }, action: .trash), min: 50 * MB)

        if let brew = Shell.which("brew") {
            let dry = await Shell.run(brew, ["cleanup", "--prune=all", "-n"])
            if let size = parseBrewEstimate(dry.combined), size >= 50 * MB {
                recs.append(Recommendation(id: "brew", title: "Homebrew cleanup",
                                           summary: "Removes old versions of installed formulae and stale downloads.",
                                           symbol: "mug", safety: .safe, group: .developer,
                                           entries: [], action: .command(executable: brew, args: ["cleanup", "--prune=all", "-s"], perEntry: false, admin: false),
                                           sizeOverride: size))
            }
        }

        recs += projectArtifacts()

        if let docker = node(home + "/Library/Containers/com.docker.docker/Data/vms"), docker.size > 500 * MB {
            let exe = Shell.which("docker")
            recs.append(Recommendation(id: "docker", title: "Docker images & volumes",
                                       summary: "Docker's virtual disk grows with images, build cache and stopped containers. Pruning removes everything not used by a running container.",
                                       symbol: "cube.box", safety: .careful, group: .developer,
                                       entries: [entry(docker, name: "Docker virtual disk", preselected: false)],
                                       action: exe.map { .command(executable: $0, args: ["system", "prune", "-a", "-f"], perEntry: false, admin: false) }
                                           ?? .guidance(openTitle: "Open Docker", open: URL(fileURLWithPath: "/Applications/Docker.app"))))
        }

        // MARK: Your files

        if let downloads = node(home + "/Downloads") {
            let old = downloads.children.filter { !$0.isAggregate && daysAgo($0.lastUsed) > 60 && $0.size >= MB }
            add(Recommendation(id: "old-downloads", title: "Old downloads",
                               summary: "Things in Downloads you haven't touched in over 2 months. Items older than 6 months are preselected.",
                               symbol: "arrow.down.circle", safety: .review, group: .files,
                               entries: old.map { entry($0, detail: "Last used " + Fmt.age($0.lastUsed), preselected: daysAgo($0.lastUsed) > 180) },
                               action: .trash), min: 50 * MB)
        }

        var stale: [CleanupEntry] = []
        let excluded: Set<String> = [home + "/Library", home + "/Downloads", home + "/.Trash"]
        node(home)?.walk { n in
            if n.isDirectory {
                let p = n.path
                if excluded.contains(p) || (n.parent?.path == home && n.name.hasPrefix(".")) || n.name == "node_modules" { return false }
                if n.isPackage { if n.size >= 250 * MB && !p.hasSuffix(".app") && daysAgo(n.lastUsed) > 180 { stale.append(entry(n, detail: Fmt.tildePath(n.parent?.path ?? "") + " · " + Fmt.age(n.lastUsed), preselected: false)) }; return false }
                return n.size >= 250 * MB
            }
            if !n.isAggregate && n.size >= 250 * MB && daysAgo(n.lastUsed) > 180 {
                stale.append(entry(n, detail: Fmt.tildePath(n.parent?.path ?? "") + " · " + Fmt.age(n.lastUsed), preselected: false))
            }
            return false
        }
        add(Recommendation(id: "stale-files", title: "Large files you haven't opened in 6 months",
                           summary: "Big files sitting untouched. Consider moving them to iCloud or an external drive.",
                           symbol: "clock.arrow.circlepath", safety: .review, group: .files,
                           entries: stale.sorted { $0.size > $1.size }, action: .trash), min: 250 * MB)

        var hidden: [CleanupEntry] = []
        let knownDot: Set<String> = [".Trash", ".npm", ".bun", ".gradle", ".cargo", ".yarn", ".cocoapods", ".pub-cache", ".nuget", ".composer", ".android"]
        if let h = node(home) {
            for c in h.children where c.isDirectory && c.name.hasPrefix(".") && !knownDot.contains(c.name) && c.size >= 300 * MB {
                hidden.append(entry(c, detail: hiddenFolderHint(c.name), preselected: false))
            }
        }
        add(Recommendation(id: "hidden-home", title: "Large hidden folders",
                           summary: "Invisible folders in your home folder: AI models, toolchains, editor extensions and caches. Finder doesn't show them.",
                           symbol: "eye.slash", safety: .review, group: .files,
                           entries: hidden.sorted { $0.size > $1.size }, action: .trash), min: 300 * MB)

        if let pictures = node(home + "/Pictures") {
            for lib in pictures.children where lib.name.hasSuffix(".photoslibrary") && lib.size > 3 * GB {
                recs.append(Recommendation(id: "photos-" + lib.name, title: "Optimize Photos storage",
                                           summary: "Your Photos library takes \(Fmt.bytes(lib.size)). With iCloud Photos, open Photos ▸ Settings ▸ iCloud and choose “Optimize Mac Storage” so full-size originals stay in iCloud.",
                                           symbol: "photo.stack", safety: .safe, group: .files,
                                           entries: [entry(lib, preselected: false)],
                                           action: .guidance(openTitle: "Open Photos", open: URL(fileURLWithPath: "/System/Applications/Photos.app"))))
            }
        }

        if let msgs = node(home + "/Library/Messages/Attachments"), msgs.size > 500 * MB {
            recs.append(Recommendation(id: "messages", title: "Messages attachments",
                                       summary: "Photos and videos from your conversations. Don't delete these files directly. In Messages ▸ Settings, set “Keep messages” to 1 year, or review large attachments under Settings ▸ General ▸ Storage.",
                                       symbol: "message", safety: .careful, group: .files,
                                       entries: [entry(msgs, name: "Messages attachments", preselected: false)],
                                       action: .guidance(openTitle: "Open Storage Settings", open: URL(string: "x-apple.systempreferences:com.apple.settings.Storage"))))
        }

        var outside: [CleanupEntry] = []
        if let shared = node("/Users/Shared") {
            outside += shared.children.filter { !$0.isAggregate && $0.size >= 500 * MB }
                .map { entry($0, detail: "/Users/Shared · modified " + Fmt.age($0.lastUsed), preselected: false) }
        }
        if let users = node("/Users") {
            for u in users.children where u.isDirectory && u.name != "Shared" && u.path != home && u.size >= 500 * MB {
                outside.append(entry(u, name: "User “\(u.name)”", detail: "Another account on this Mac. Remove it in System Settings ▸ Users & Groups", preselected: false))
            }
        }
        add(Recommendation(id: "outside-home", title: "Large folders outside your home",
                           summary: "Space used in /Users/Shared and other accounts. Finder's sidebar doesn't show these places, so they're easy to forget.",
                           symbol: "person.2", safety: .review, group: .files,
                           entries: outside.sorted { $0.size > $1.size }, action: .trash), min: 500 * MB)

        // MARK: Apps

        recs += unusedApps()

        // MARK: System & backups

        if let backups = node(home + "/Library/Application Support/MobileSync/Backup") {
            let entries = backups.children.filter { !$0.isAggregate }.map { b -> CleanupEntry in
                let info = NSDictionary(contentsOfFile: b.path + "/Info.plist")
                let device = info?["Device Name"] as? String ?? info?["Display Name"] as? String ?? "Device backup"
                let date = info?["Last Backup Date"] as? Date ?? b.modifiedDate
                return entry(b, name: device, detail: "Backed up " + Fmt.age(date), preselected: false)
            }
            add(Recommendation(id: "ios-backups", title: "iPhone & iPad backups",
                               summary: "Local device backups. Remove old ones if you use iCloud Backup or no longer own the device.",
                               symbol: "iphone.and.arrow.forward", safety: .careful, group: .system,
                               entries: entries, action: .trash), min: 100 * MB)
        }

        return recs
    }

    // MARK: - Helpers

    private func hiddenFolderHint(_ name: String) -> String {
        switch name {
        case ".ollama": "Ollama AI models"
        case ".cache": "Tool caches (Hugging Face, pip, uv…)"
        case ".rustup": "Rust toolchains"
        case ".nvm": "Node.js versions"
        case ".pyenv": "Python versions"
        case ".vscode", ".cursor", ".windsurf": "Editor extensions"
        case ".docker": "Docker config & contexts"
        case ".m2": "Maven repository"
        case ".lmstudio": "LM Studio models"
        case ".local": "Local tools & data"
        case ".claude": "Claude Code data"
        default: "Hidden folder"
        }
    }

    private func parseBrewEstimate(_ output: String) -> Int64? {
        // "==> This operation would free approximately 1.2GB of disk space."
        guard let range = output.range(of: #"approximately ([0-9.]+)([KMGT]?B)"#, options: .regularExpression) else { return nil }
        let match = String(output[range]).replacingOccurrences(of: "approximately ", with: "")
        let num = Double(match.filter { "0123456789.".contains($0) }) ?? 0
        let unit = match.filter { $0.isLetter }
        let mult: Double = switch unit { case "KB": 1e3; case "MB": 1e6; case "GB": 1e9; case "TB": 1e12; default: 1 }
        return Int64(num * mult)
    }

    private func projectArtifacts() -> [Recommendation] {
        var found: [CleanupEntry] = []
        let skipTop: Set<String> = [home + "/Library", home + "/.Trash", home + "/Applications"]
        let fm = FileManager.default
        let visit: (FileNode) -> Bool = { n in
            guard n.isDirectory, !n.isPackage else { return false }
            if n.size < 20 * MB { return false }
            let p = n.path
            if skipTop.contains(p) || (n.parent?.path == home && n.name.hasPrefix(".")) { return false }
            let parentPath = n.parent?.path ?? ""
            var kind: String?
            switch n.name {
            case "node_modules": kind = "Node packages"
            case ".venv", "venv", "env": if fm.fileExists(atPath: p + "/pyvenv.cfg") { kind = "Python virtualenv" }
            case "target": if fm.fileExists(atPath: parentPath + "/Cargo.toml") { kind = "Rust build output" }
            case "Pods": if fm.fileExists(atPath: parentPath + "/Podfile") { kind = "CocoaPods" }
            case ".build": if fm.fileExists(atPath: parentPath + "/Package.swift") { kind = "SwiftPM build" }
            case ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".expo": kind = "Framework build cache"
            case ".gradle", "build": if fm.fileExists(atPath: parentPath + "/build.gradle") || fm.fileExists(atPath: parentPath + "/build.gradle.kts") { kind = "Gradle build" }
            default: break
            }
            if let kind {
                let project = (parentPath as NSString).lastPathComponent
                let age = daysAgo(n.parent?.lastUsed ?? n.lastUsed)
                found.append(entry(n, name: project + " › " + n.name,
                                   detail: "\(kind) · project touched \(Fmt.age(n.parent?.lastUsed ?? n.lastUsed))",
                                   preselected: age > 30))
                return false
            }
            return true
        }
        node(home)?.walk(visit)
        node("/Users/Shared")?.walk(visit)
        guard found.reduce(0, { $0 + $1.size }) >= 50 * MB else { return [] }
        return [Recommendation(id: "project-artifacts", title: "Project dependencies & build output",
                               summary: "node_modules, virtualenvs and build folders. Reinstall them with your package manager when you return to a project. Projects untouched for 30+ days are preselected.",
                               symbol: "folder.badge.gearshape", safety: .review, group: .developer,
                               entries: found.sorted { $0.size > $1.size }, action: .trash)]
    }

    private func simulatorRecommendations() async -> [Recommendation] {
        var recs: [Recommendation] = []
        let devicesDir = home + "/Library/Developer/CoreSimulator/Devices"

        let list = await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
        if let data = list.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            var unavailable: [CleanupEntry] = []
            for (runtime, list) in devices {
                for d in list where (d["isAvailable"] as? Bool) == false {
                    guard let udid = d["udid"] as? String, let n = node(devicesDir + "/" + udid) else { continue }
                    let rt = runtime.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: " ") ?? runtime
                    unavailable.append(entry(n, name: d["name"] as? String ?? udid, detail: rt + " (runtime removed)"))
                }
            }
            if unavailable.reduce(0, { $0 + $1.size }) > 20 * MB {
                recs.append(Recommendation(id: "sim-unavailable", title: "Orphaned simulators",
                                           summary: "Simulators whose iOS version is no longer installed. They can't be booted anymore.",
                                           symbol: "iphone.slash", safety: .safe, group: .developer,
                                           entries: unavailable.sorted { $0.size > $1.size },
                                           action: .command(executable: "/usr/bin/xcrun", args: ["simctl", "delete", "unavailable"], perEntry: false, admin: false)))
            }
        }

        let rt = await Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
        if let data = rt.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            let iso = ISO8601DateFormatter()
            let entries: [CleanupEntry] = json.values.compactMap { r in
                guard let id = r["identifier"] as? String, (r["deletable"] as? Bool) ?? true else { return nil }
                let size = (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0
                let platform = (r["platformIdentifier"] as? String ?? "").contains("iphone") ? "iOS"
                    : (r["platformIdentifier"] as? String ?? "").replacingOccurrences(of: "com.apple.platform.", with: "").replacingOccurrences(of: "simulator", with: "")
                let version = r["version"] as? String ?? "?"
                let lastUsed = (r["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
                let path = r["path"] as? String ?? "/Library/Developer/CoreSimulator"
                return CleanupEntry(id: "runtime-" + id, name: "\(platform) \(version) Simulator",
                                    detail: lastUsed.map { "Last used " + Fmt.age($0) } ?? "Never used",
                                    size: size, url: URL(fileURLWithPath: path), node: nil, lastUsed: lastUsed,
                                    preselected: lastUsed.map { daysAgo($0) > 60 } ?? true, commandArgument: id)
            }
            if !entries.isEmpty {
                recs.append(Recommendation(id: "sim-runtimes", title: "Simulator runtimes",
                                           summary: "Each iOS/watchOS simulator version is a multi-GB disk image. Keep only the ones you test on. Xcode ▸ Settings ▸ Components can download them again.",
                                           symbol: "square.stack.3d.down.right", safety: .review, group: .developer,
                                           entries: entries.sorted { $0.size > $1.size },
                                           action: .command(executable: "/usr/bin/xcrun", args: ["simctl", "runtime", "delete"], perEntry: true, admin: false)))
            }
        }
        return recs
    }

    private func unusedApps() -> [Recommendation] {
        var entries: [CleanupEntry] = []
        let selfPath = Bundle.main.bundlePath
        for base in ["/Applications", home + "/Applications"] {
            guard let dir = node(base) else { continue }
            var apps: [FileNode] = []
            for c in dir.children where c.isDirectory {
                if c.name.hasSuffix(".app") { apps.append(c) }
                else if !c.isPackage { apps += c.children.filter { $0.name.hasSuffix(".app") } } // e.g. /Applications/Utilities-like folders
            }
            for app in apps where app.size >= 50 * MB && app.path != selfPath {
                var lastUsed: Date?
                if let item = MDItemCreate(nil, app.path as CFString),
                   let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { lastUsed = d }
                let days = lastUsed.map(daysAgo) ?? Int.max
                guard days > 90 else { continue }
                var e = entry(app, name: (app.name as NSString).deletingPathExtension,
                              detail: lastUsed.map { "Last opened " + Fmt.age($0) } ?? "Never opened on this Mac",
                              preselected: false)
                e.lastUsed = lastUsed
                entries.append(e)
            }
        }
        guard entries.reduce(0, { $0 + $1.size }) >= 100 * MB else { return [] }
        return [Recommendation(id: "unused-apps", title: "Apps you don't use",
                               summary: "Apps not opened in the last 3 months. You can reinstall App Store apps anytime from your purchases.",
                               symbol: "app.dashed", safety: .review, group: .apps,
                               entries: entries.sorted { $0.size > $1.size }, action: .trash)]
    }
}
