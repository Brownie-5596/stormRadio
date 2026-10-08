import Foundation

/// Known NWS alert event names, grouped for the settings screens, with sensible defaults.
public enum ProductCatalog {
    public struct Entry: Sendable {
        public var event: String
        public var group: String
        public var rule: ProductRule
    }

    public static let groups = ["Severe / Tornado", "Flooding", "Tropical", "Winter", "Wind / Fire / Other"]

    public static let entries: [Entry] = [
        // Severe / Tornado
        Entry(event: "Tornado Warning", group: groups[0],
              rule: ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 75, priority: 9, canInterrupt: true)),
        Entry(event: "Extreme Wind Warning", group: groups[0],
              rule: ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 75, priority: 9, canInterrupt: true)),
        Entry(event: "Severe Thunderstorm Warning", group: groups[0],
              rule: ProductRule(mode: .toneThenSpeak, tone: .tripleBeep, maxDistanceMiles: 40, priority: 7, canInterrupt: true)),
        Entry(event: "Special Weather Statement", group: groups[0],
              rule: ProductRule(mode: .speak, tone: .ping, maxDistanceMiles: 15, priority: 3, announceEnding: false)),
        Entry(event: "Tornado Watch", group: groups[0],
              rule: ProductRule(mode: .toneThenSpeak, tone: .chimeUp, maxDistanceMiles: 25, priority: 6)),
        Entry(event: "Severe Thunderstorm Watch", group: groups[0],
              rule: ProductRule(mode: .toneThenSpeak, tone: .chimeUp, maxDistanceMiles: 15, priority: 5)),
        Entry(event: "Snow Squall Warning", group: groups[0],
              rule: ProductRule(mode: .toneThenSpeak, tone: .doubleBeep, maxDistanceMiles: 25, priority: 6)),
        Entry(event: "Dust Storm Warning", group: groups[0],
              rule: ProductRule(mode: .toneThenSpeak, tone: .doubleBeep, maxDistanceMiles: 25, priority: 6)),
        Entry(event: "Dust Advisory", group: groups[0], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        // Flooding
        Entry(event: "Flash Flood Warning", group: groups[1],
              rule: ProductRule(mode: .toneThenSpeak, tone: .doubleBeep, maxDistanceMiles: 15, priority: 6, canInterrupt: false)),
        Entry(event: "Flash Flood Watch", group: groups[1], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 3)),
        Entry(event: "Flood Warning", group: groups[1], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 3)),
        Entry(event: "Flood Advisory", group: groups[1], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        Entry(event: "Flood Watch", group: groups[1], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        // Tropical
        Entry(event: "Hurricane Warning", group: groups[2], rule: ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 0, priority: 7)),
        Entry(event: "Hurricane Watch", group: groups[2], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 4)),
        Entry(event: "Tropical Storm Warning", group: groups[2], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 5)),
        Entry(event: "Tropical Storm Watch", group: groups[2], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 3)),
        Entry(event: "Storm Surge Warning", group: groups[2], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 6)),
        Entry(event: "Storm Surge Watch", group: groups[2], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 3)),
        // Winter
        Entry(event: "Blizzard Warning", group: groups[3], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 5)),
        Entry(event: "Winter Storm Warning", group: groups[3], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 4)),
        Entry(event: "Ice Storm Warning", group: groups[3], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 4)),
        Entry(event: "Winter Storm Watch", group: groups[3], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        Entry(event: "Winter Weather Advisory", group: groups[3], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        Entry(event: "Extreme Cold Warning", group: groups[3], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        // Wind / fire / other
        Entry(event: "High Wind Warning", group: groups[4], rule: ProductRule(mode: .speak, maxDistanceMiles: 0, priority: 4)),
        Entry(event: "Wind Advisory", group: groups[4], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        Entry(event: "Fire Warning", group: groups[4], rule: ProductRule(mode: .toneThenSpeak, tone: .doubleBeep, maxDistanceMiles: 10, priority: 6)),
        Entry(event: "Red Flag Warning", group: groups[4], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        Entry(event: "Extreme Heat Warning", group: groups[4], rule: ProductRule(enabled: false, mode: .notifyOnly, maxDistanceMiles: 0, priority: 2)),
        Entry(event: "Civil Emergency Message", group: groups[4], rule: ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 0, priority: 8, canInterrupt: true)),
        Entry(event: "Shelter In Place Warning", group: groups[4], rule: ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 5, priority: 8, canInterrupt: true)),
        Entry(event: "Evacuation Immediate", group: groups[4], rule: ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 0, priority: 8, canInterrupt: true)),
    ]

    public static var defaultRules: [String: ProductRule] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.event, $0.rule) })
    }

    public static func group(for event: String) -> String? {
        entries.first(where: { $0.event == event })?.group
    }
}

// MARK: - Default profiles

public extension Profile {
    /// Storm chasing: follow GPS, everything convective, path alerts, nearby reports.
    static var chase: Profile {
        Profile(id: "chase", name: "Chase")
    }

    /// At home: fixed point (set it in settings), tighter distances, no SPS chatter from far away.
    static var home: Profile {
        var p = Profile(id: "home", name: "Home")
        p.location = LocationSettings(mode: .fixed, radiusMiles: 40)
        p.alertRules["Severe Thunderstorm Warning"]?.maxDistanceMiles = 20
        p.alertRules["Tornado Warning"]?.maxDistanceMiles = 40
        p.alertRules["Special Weather Statement"]?.maxDistanceMiles = 5
        p.reports.maxDistanceMiles = 15
        p.spc.mdNationwide = false
        p.spc.mdMaxDistanceMiles = 150
        return p
    }

    /// Weather-aware but quiet: tones for most things, speech only for tornado-level threats.
    static var quiet: Profile {
        var p = Profile(id: "quiet", name: "Quiet (tones)")
        for (k, var r) in p.alertRules where r.enabled {
            if k != "Tornado Warning" && k != "Extreme Wind Warning" { r.mode = .tone; if r.tone == .none { r.tone = .blip } }
            p.alertRules[k] = r
        }
        p.reports.categories[ReportCategory.hail.rawValue]?.mode = .tone
        p.reports.categories[ReportCategory.windGust.rawValue]?.mode = .tone
        p.reports.categories[ReportCategory.windDamage.rawValue]?.mode = .tone
        p.spc.mdMode = .tone
        p.spc.outlookEnabled = false
        p.afd.enabled = false
        p.path.minimumRisk = 4
        return p
    }

    /// Overnight / sleeping: only tornado, extreme wind, PDS/destructive situations at your location.
    static var overnight: Profile {
        var p = Profile(id: "overnight", name: "Overnight (life-threatening only)")
        for k in p.alertRules.keys { p.alertRules[k]?.enabled = false }
        p.alertRules["Tornado Warning"] = ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 5, priority: 10, canInterrupt: true)
        p.alertRules["Extreme Wind Warning"] = ProductRule(mode: .toneThenSpeak, tone: .eas, maxDistanceMiles: 0, priority: 10, canInterrupt: true)
        p.alertRules["Severe Thunderstorm Warning"] = ProductRule(mode: .toneThenSpeak, tone: .tripleBeep, maxDistanceMiles: 0, priority: 7)
        p.alertRules["Flash Flood Warning"] = ProductRule(mode: .toneThenSpeak, tone: .doubleBeep, maxDistanceMiles: 0, priority: 6)
        p.location = LocationSettings(mode: .fixed, radiusMiles: 25)
        p.updates.extensions = false
        p.updates.areaReduced = false
        p.updates.cancellations = false
        p.updates.expirations = false
        p.updates.leftWarning = false
        p.reports.enabled = false
        p.spc.mdEnabled = false
        p.spc.watchEnabled = false
        p.spc.outlookEnabled = false
        p.afd.enabled = false
        p.path.minimumRisk = 4
        p.startupSummary = false
        return p
    }
}
