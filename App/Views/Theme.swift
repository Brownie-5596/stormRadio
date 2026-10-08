import SwiftUI
import StormRadioCore

/// Colors and icons for alert types, report types and feed categories.
enum Theme {
    static func color(forEvent event: String) -> Color {
        switch event {
        case "Tornado Warning", "Extreme Wind Warning": return .red
        case "Severe Thunderstorm Warning": return .orange
        case "Flash Flood Warning": return .green
        case "Special Weather Statement": return Color(red: 0.4, green: 0.75, blue: 1.0)
        case "Tornado Watch": return .yellow
        case "Severe Thunderstorm Watch": return .pink
        case "Flash Flood Watch", "Flood Watch": return .mint
        case "Flood Warning", "Flood Advisory": return Color(red: 0.0, green: 0.6, blue: 0.3)
        case "Snow Squall Warning", "Blizzard Warning", "Winter Storm Warning", "Ice Storm Warning": return .cyan
        case "Dust Storm Warning": return .brown
        case "Hurricane Warning", "Tropical Storm Warning", "Storm Surge Warning": return .purple
        case "MD": return .blue
        case "Outlook": return .teal
        case "AFD": return .gray
        default: return .secondary
        }
    }

    static func color(forReport c: ReportCategory) -> Color {
        switch c {
        case .tornado: return .red
        case .funnelCloud, .wallCloud: return .orange
        case .hail: return .green
        case .windGust, .windDamage: return .blue
        case .flashFlood, .flood, .heavyRain: return .teal
        case .snow: return .cyan
        case .other: return .gray
        }
    }

    static func icon(forReport c: ReportCategory) -> String {
        switch c {
        case .tornado: return "tornado"
        case .funnelCloud, .wallCloud: return "cloud"
        case .hail: return "cloud.hail"
        case .windGust, .windDamage: return "wind"
        case .flashFlood, .flood: return "water.waves"
        case .heavyRain: return "cloud.heavyrain"
        case .snow: return "snowflake"
        case .other: return "exclamationmark.bubble"
        }
    }

    static func icon(for a: Announcement) -> String {
        switch a.category {
        case .warning:
            if let k = a.kind, k.contains("Tornado") { return "tornado" }
            if let k = a.kind, k.contains("Flood") { return "water.waves" }
            if let k = a.kind, k.contains("Watch") { return "eye" }
            return "cloud.bolt.rain"
        case .update: return "arrow.triangle.2.circlepath"
        case .location: return "location.circle"
        case .path: return "arrow.right.to.line.compact"
        case .report:
            if let k = a.kind, let c = ReportCategory(rawValue: k) { return icon(forReport: c) }
            return "person.wave.2"
        case .md: return "doc.text.magnifyingglass"
        case .watch: return "eye.trianglebadge.exclamationmark"
        case .outlook: return "map"
        case .afd: return "text.book.closed"
        case .summary: return "list.bullet.rectangle"
        case .system: return "gear"
        }
    }

    static func color(for a: Announcement) -> Color {
        switch a.category {
        case .report:
            if let k = a.kind, let c = ReportCategory(rawValue: k) { return color(forReport: c) }
            return .purple
        case .path: return .red
        case .md: return .blue
        case .watch: return .yellow
        case .outlook: return .teal
        case .afd: return .gray
        case .summary, .system: return .secondary
        default: return color(forEvent: a.kind ?? "")
        }
    }

    static func riskColor(_ r: Int) -> Color {
        switch r {
        case 5: return .purple
        case 4: return .red
        case 3: return .orange
        case 2: return .yellow
        case 1: return .green
        default: return .gray
        }
    }
}

extension Date {
    /// "3 min ago", "just now"
    var ago: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        if s < 86400 { return "\(s / 3600) hr \((s % 3600) / 60) min ago" }
        return formatted(date: .abbreviated, time: .shortened)
    }
}
