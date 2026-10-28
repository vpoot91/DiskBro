import Foundation
import AppKit

struct VolumeStats: Equatable, Sendable {
    var total: Int64 = 0
    var available: Int64 = 0
    /// What macOS reports as available once purgeable space is reclaimed.
    var availableForImportant: Int64 = 0

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableForImportant - available) }
    var freeFraction: Double { total > 0 ? Double(available) / Double(total) : 0 }

    enum Health { case good, low, critical }
    var health: Health {
        let gb = Double(available) / 1e9
        if gb < 10 || freeFraction < 0.05 { return .critical }
        if gb < 25 || freeFraction < 0.12 { return .low }
        return .good
    }

    static func current() -> VolumeStats {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return VolumeStats() }
        let avail = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeStats(total: Int64(v.volumeTotalCapacity ?? 0),
                           available: avail,
                           availableForImportant: max(avail, v.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

struct APFSVolume: Identifiable, Sendable {
    let id: String
    let name: String
    let roles: [String]
    let used: Int64

    var role: String { roles.first ?? "" }

    var friendlyName: String {
        switch role {
        case "System": "macOS (sealed system)"
        case "Data": "Your data"
        case "VM": "Swap & sleep image"
        case "Preboot": "Preboot (boot files, cryptexes)"
        case "Recovery": "Recovery"
        case "Update": "Software update staging"
        default: name
        }
    }
}

struct APFSContainer: Sendable {
    let capacity: Int64
    let free: Int64
    let volumes: [APFSVolume]
    var used: Int64 { capacity - free }
    func volume(role: String) -> APFSVolume? { volumes.first { $0.roles.contains(role) } }

    /// Reads `diskutil apfs list -plist` and returns the container holding the boot System volume.
    static func load() async -> APFSContainer? {
        let out = await Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"])
        guard out.status == 0,
              let data = out.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        for c in containers {
            let vols = (c["Volumes"] as? [[String: Any]] ?? []).map { v in
                APFSVolume(id: v["DeviceIdentifier"] as? String ?? UUID().uuidString,
                           name: v["Name"] as? String ?? "?",
                           roles: v["Roles"] as? [String] ?? [],
                           used: (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
            }
            if vols.contains(where: { $0.roles.contains("System") }) {
                return APFSContainer(capacity: (c["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0,
                                     free: (c["CapacityFree"] as? NSNumber)?.int64Value ?? 0,
                                     volumes: vols.sorted { $0.used > $1.used })
            }
        }
        return nil
    }
}

struct LocalSnapshot: Identifiable, Sendable {
    let id: String     // full name
    let dateString: String
    var date: Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: dateString)
    }

    static func list() async -> [LocalSnapshot] {
        let out = await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        return out.stdout.split(separator: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("com.apple.") else { return nil }
            let parts = s.split(separator: ".")
            let date = parts.first { $0.count == 17 && $0.contains("-") }.map(String.init) ?? ""
            return LocalSnapshot(id: s, dateString: date)
        }
    }
}

enum Permissions {
    /// Probes TCC-protected locations. Readable means Full Disk Access is granted.
    static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        let probes = [
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/.Trash",
            "/Library/Application Support/com.apple.TCC",
        ]
        for p in probes where FileManager.default.fileExists(atPath: p) {
            if let dir = opendir(p) { closedir(dir); return true }
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ShellResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var combined: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum Shell {
    static func run(_ executable: String, _ args: [String], environment: [String: String]? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                environment?.forEach { env[$0] = $1 }
                p.environment = env
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                // Read before waiting so large outputs can't deadlock on a full pipe.
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: ShellResult(status: p.terminationStatus,
                                                   stdout: String(decoding: out, as: UTF8.self),
                                                   stderr: String(decoding: err, as: UTF8.self)))
            }
        }
    }

    /// Runs a shell command line with the standard macOS administrator prompt.
    static func runAsAdmin(_ commandLine: String) async -> ShellResult {
        let escaped = commandLine.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }

    static func which(_ tool: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/Applications/Docker.app/Contents/Resources/bin"] {
            let p = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func quoted(_ args: [String]) -> String {
        args.map { a in
            a.rangeOfCharacter(from: .whitespaces.union(CharacterSet(charactersIn: "'\"$`\\"))) == nil
                ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
