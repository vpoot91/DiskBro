import SwiftUI

/// Fixed order maps 1:1 to the categorical palette slots, so a category keeps its color everywhere.
enum StorageCategory: Int, CaseIterable, Identifiable, Sendable {
    case apps, developer, media, documents, appData, system, other

    var id: Int { rawValue }
    var color: Color { Palette.series[rawValue] }

    var title: String {
        switch self {
        case .apps: "Applications"
        case .developer: "Developer"
        case .media: "Photos, Music & Video"
        case .documents: "Documents & Downloads"
        case .appData: "App Data & Caches"
        case .system: "macOS & System"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "app.badge"
        case .developer: "hammer"
        case .media: "photo.on.rectangle"
        case .documents: "doc.on.doc"
        case .appData: "shippingbox"
        case .system: "apple.logo"
        case .other: "ellipsis.circle"
        }
    }
}

enum CategoryBreakdown {
    static func compute(root: FileNode) -> [StorageCategory: Int64] {
        let home = NSHomeDirectory()
        var exact: [String: StorageCategory] = [
            "/Applications": .apps, home + "/Applications": .apps,
            "/System": .system, "/Library": .system, "/usr": .system, "/bin": .system, "/sbin": .system,
            "/private": .system, "/cores": .system, "/opt": .developer, "/usr/local": .developer,
            "/Library/Developer": .developer, "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime": .developer,
            home + "/Library": .appData,
            home + "/Library/Developer": .developer,
            home + "/Library/Containers/com.docker.docker": .developer,
            home + "/Library/pnpm": .developer,
            home + "/Library/Caches/Homebrew": .developer,
            home + "/Library/Mobile Documents": .documents, home + "/.Trash": .other,
            home + "/Movies": .media, home + "/Music": .media, home + "/Pictures": .media,
            home + "/Documents": .documents, home + "/Desktop": .documents, home + "/Downloads": .documents,
        ]
        for dir in ["Projects", "Developer", "Code", "code", "dev", "src", "git", "GitHub", "repos", "Sites", "go"] {
            exact[home + "/" + dir] = .developer
        }
        let devNames: Set<String> = ["node_modules", ".git", "DerivedData", "Pods", ".venv", ".gradle", ".next", ".turbo"]
        var totals: [StorageCategory: Int64] = [:]

        func visit(_ node: FileNode, path: String, parentPath: String, inherited: StorageCategory) {
            var cat = exact[path] ?? inherited
            if devNames.contains(node.name) { cat = .developer }
            else if parentPath == home, node.name.hasPrefix("."), exact[path] == nil { cat = .developer }
            for c in node.children {
                if c.isDirectory {
                    visit(c, path: path == "/" ? "/" + c.name : path + "/" + c.name, parentPath: path, inherited: cat)
                } else {
                    totals[cat, default: 0] += c.size
                }
            }
        }
        visit(root, path: root.name, parentPath: "", inherited: .other)
        return totals
    }
}
