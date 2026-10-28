import SwiftUI
import AppKit

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        if b <= 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// Splits "12.4 GB" into ("12.4", "GB") for hero numbers.
    static func bytesParts(_ b: Int64) -> (String, String) {
        let s = bytes(b)
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (s, "")
    }

    static func signedBytes(_ b: Int64) -> String {
        (b >= 0 ? "+" : "−") + bytes(abs(b))
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: .now)
    }

    static func age(_ date: Date) -> String {
        let days = Int(Date.now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case ..<30: return "\(days) days ago"
        case ..<365: return "\(days / 30) mo ago"
        default:
            let years = Double(days) / 365
            return years < 2 ? "1 yr ago" : "\(Int(years)) yrs ago"
        }
    }

    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// Validated categorical palette (fixed order, never cycled) with selected dark steps.
enum Palette {
    static let series: [Color] = [
        .dynamic(light: 0x2a78d6, dark: 0x3987e5), // blue
        .dynamic(light: 0xeb6834, dark: 0xd95926), // orange
        .dynamic(light: 0x1baf7a, dark: 0x199e70), // aqua
        .dynamic(light: 0xeda100, dark: 0xc98500), // yellow
        .dynamic(light: 0xe87ba4, dark: 0xd55181), // magenta
        .dynamic(light: 0x008300, dark: 0x008300), // green
        .dynamic(light: 0x6250d6, dark: 0x9085e9), // violet
        .dynamic(light: 0xe34948, dark: 0xe66767), // red
    ]
    static let neutral = Color.dynamic(light: 0xb4b2ab, dark: 0x5c5b57)
    static let hidden = Color.dynamic(light: 0x8a8984, dark: 0x7a7974)
    static let track = Color.primary.opacity(0.07)

    static let good = Color.dynamic(light: 0x1f8a4c, dark: 0x3fb871)
    static let warning = Color.dynamic(light: 0xc27c00, dark: 0xf0a92a)
    static let critical = Color.dynamic(light: 0xd1344a, dark: 0xf2667a)
}
