import Foundation

// MARK: - Building blocks

/// What to do when something should be announced.
public enum AnnounceMode: String, Codable, CaseIterable, Sendable {
    case speak            // read it aloud
    case toneThenSpeak    // play the tone, then read it
    case tone             // tone only (different tone per product)
    case notifyOnly       // silent: feed + iOS notification only
    case off              // ignore completely

    public var label: String {
        switch self {
        case .speak: return "Speak"
        case .toneThenSpeak: return "Tone + Speak"
        case .tone: return "Tone only"
        case .notifyOnly: return "Silent (feed only)"
        case .off: return "Off"
        }
    }

    public var speaks: Bool { self == .speak || self == .toneThenSpeak }
    public var playsTone: Bool { self == .tone || self == .toneThenSpeak }
}

/// An alert sound: one of the built-in synthesized tones, or a custom audio file ("custom:<file name>").
/// Stored in settings as a plain string, so older settings files keep working.
public struct ToneID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let none = ToneID("none")
    public static let eas = ToneID("eas")                 // EAS-style two-tone attention signal
    public static let nwr1050 = ToneID("nwr1050")         // NOAA Weather Radio 1050 Hz warning alarm tone
    public static let siren = ToneID("siren")             // rising/falling sweep
    public static let alarm = ToneID("alarm")             // fast alternating hi/lo
    public static let tripleBeep = ToneID("tripleBeep")
    public static let doubleBeep = ToneID("doubleBeep")
    public static let chimeUp = ToneID("chimeUp")
    public static let chimeDown = ToneID("chimeDown")
    public static let ping = ToneID("ping")
    public static let blip = ToneID("blip")

    /// The built-in tones, in menu order.
    public static let builtIn: [ToneID] = [.none, .eas, .nwr1050, .siren, .alarm, .tripleBeep, .doubleBeep, .chimeUp, .chimeDown, .ping, .blip]
    /// Same as `builtIn` (kept for older code).
    public static var allCases: [ToneID] { builtIn }

    public static let customPrefix = "custom:"

    /// A custom sound file stored in the app's Sounds folder.
    public static func custom(_ fileName: String) -> ToneID { ToneID(customPrefix + fileName) }

    public var isCustom: Bool { rawValue.hasPrefix(Self.customPrefix) }
    public var customFileName: String? { isCustom ? String(rawValue.dropFirst(Self.customPrefix.count)) : nil }

    public var label: String {
        if let f = customFileName { return (f as NSString).deletingPathExtension }
        switch self {
        case .none: return "None"
        case .eas: return "EAS two-tone"
        case .nwr1050: return "NOAA 1050 Hz"
        case .siren: return "Siren sweep"
        case .alarm: return "Alarm (hi/lo)"
        case .tripleBeep: return "Triple beep"
        case .doubleBeep: return "Double beep"
        case .chimeUp: return "Chime up"
        case .chimeDown: return "Chime down"
        case .ping: return "Ping"
        case .blip: return "Soft blip"
        default: return rawValue
        }
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Per-product (per NWS event type) settings.
public struct ProductRule: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var mode: AnnounceMode
    public var tone: ToneID
    /// Announce only when the alert is within this many miles of you. 0 = only when you are inside it.
    public var maxDistanceMiles: Double
    /// 1 (lowest) ... 10 (highest). Decides queue order and what may interrupt what.
    public var priority: Int
    /// May this product cut off a lower-priority message that is currently being read?
    public var canInterrupt: Bool
    /// Announce updates (threat changes, extensions, area changes).
    public var announceUpdates: Bool
    /// Announce cancellations / expirations.
    public var announceEnding: Bool
    /// Also post an iOS notification.
    public var notify: Bool

    public init(enabled: Bool = true, mode: AnnounceMode = .speak, tone: ToneID = .none, maxDistanceMiles: Double = 25,
                priority: Int = 5, canInterrupt: Bool = false, announceUpdates: Bool = true, announceEnding: Bool = true,
                notify: Bool = true) {
        self.enabled = enabled
        self.mode = mode
        self.tone = tone
        self.maxDistanceMiles = maxDistanceMiles
        self.priority = priority
        self.canInterrupt = canInterrupt
        self.announceUpdates = announceUpdates
        self.announceEnding = announceEnding
        self.notify = notify
    }

    public static let disabled = ProductRule(enabled: false, mode: .off, maxDistanceMiles: 0, priority: 1,
                                             announceUpdates: false, announceEnding: false, notify: false)
}

/// The pieces a warning announcement can be built from. Users reorder and toggle these.
public enum PhraseBlockKind: String, Codable, CaseIterable, Sendable {
    case tags              // PDS / emergency / considerable / destructive (inline with the event name)
    case event             // "severe thunderstorm warning"
    case office            // "by the National Weather Service in Norman"
    case issuedAgo         // "6 minutes ago"
    case distance          // "6 miles to the northeast" / "for your location"
    case threats           // "60 mile per hour wind gusts were indicated by radar, and 2 inch hail was observed"
    case source            // "Source: law enforcement reported a tornado."
    case hazardText        // the HAZARD... line, used when there are no IBW threat tags (e.g. SPS)
    case storm             // "The storm is 12 miles to the west, moving northeast at 35 miles per hour."
    case motion            // "Moving northeast at 35 miles per hour."
    case expires           // "It expires in 50 minutes, at 7:30."
    case cities            // "Locations include Moore, Norman and Noble."
    case counties          // "Including Cleveland and McClain counties."
    case path              // "You are in the path, arrival in about 15 minutes."
    case headline          // NWS headline text
    case instructions      // first sentence of the call to action

    public var label: String {
        switch self {
        case .tags: return "Tags (PDS, Emergency, Considerable, Destructive)"
        case .event: return "Warning type"
        case .office: return "Issuing NWS office"
        case .issuedAgo: return "Issued X minutes ago"
        case .distance: return "Distance & direction from you"
        case .threats: return "Threats & how they were detected"
        case .source: return "Source line (who reported it)"
        case .hazardText: return "Hazard text (when no threat tags)"
        case .storm: return "Storm location & motion"
        case .motion: return "Storm motion only"
        case .expires: return "Expiration time"
        case .cities: return "Cities in the warning"
        case .counties: return "Counties / areas"
        case .path: return "In-path arrival estimate"
        case .headline: return "NWS headline"
        case .instructions: return "Instructions (take cover...)"
        }
    }

    /// Placeholder used by the custom text format, e.g. "{threats}".
    public var placeholder: String { "{\(rawValue)}" }
}

public struct TemplateBlock: Codable, Hashable, Identifiable, Sendable {
    public var kind: PhraseBlockKind
    public var enabled: Bool
    public var id: String { kind.rawValue }

    public init(_ kind: PhraseBlockKind, _ enabled: Bool = true) {
        self.kind = kind
        self.enabled = enabled
    }
}

/// How an alert announcement is assembled: either ordered blocks, or a free-form text format with placeholders.
public struct MessageTemplate: Codable, Hashable, Sendable {
    public var useCustomFormat: Bool
    public var blocks: [TemplateBlock]
    /// Example: "{tags} {event} {distance}. {threats}. {expires}"
    public var customFormat: String

    public init(useCustomFormat: Bool = false, blocks: [TemplateBlock], customFormat: String) {
        self.useCustomFormat = useCustomFormat
        self.blocks = blocks
        self.customFormat = customFormat
    }

    public static let standard = MessageTemplate(
        blocks: [
            TemplateBlock(.tags), TemplateBlock(.event), TemplateBlock(.office, false), TemplateBlock(.issuedAgo),
            TemplateBlock(.distance), TemplateBlock(.threats), TemplateBlock(.source), TemplateBlock(.hazardText),
            TemplateBlock(.storm, false), TemplateBlock(.motion, false), TemplateBlock(.path),
            TemplateBlock(.expires), TemplateBlock(.cities, false), TemplateBlock(.counties, false),
            TemplateBlock(.headline, false), TemplateBlock(.instructions, false),
        ],
        customFormat: "{tags} {event} {issuedAgo} {distance}. {threats}. {source}. {path}. {expires}"
    )

    /// Adds any block kinds missing from older settings files (disabled, at the end).
    public mutating func normalize() {
        var seen = Set<PhraseBlockKind>()
        blocks = blocks.filter { seen.insert($0.kind).inserted }
        for k in PhraseBlockKind.allCases where !seen.contains(k) {
            blocks.append(TemplateBlock(k, false))
        }
    }
}

public enum DistanceMeasure: String, Codable, CaseIterable, Sendable {
    case nearestEdge   // to the closest edge of the warning polygon
    case center        // to the polygon's center
    case storm         // to the storm location given by the NWS (falls back to nearest edge)

    public var label: String {
        switch self {
        case .nearestEdge: return "Nearest edge of warning"
        case .center: return "Center of warning"
        case .storm: return "Storm location (if given)"
        }
    }
}

public enum HailStyle: String, Codable, CaseIterable, Sendable {
    case inchesAndObject   // "2 inch, hen egg size hail"
    case inches            // "2 inch hail"
    case object            // "hen egg size hail"
}

/// Fine-grained wording options.
public struct PhraseOptions: Codable, Hashable, Sendable {
    /// Say "issued N minutes ago" only when the alert is at least this old. -1 = never.
    public var issuedAgoMinMinutes: Int
    /// ...and not when it is older than this (long-running alerts like flood warnings).
    public var issuedAgoMaxMinutes: Int
    public var expiresRelative: Bool        // "in 50 minutes"
    public var expiresClock: Bool           // "at 7:30"
    public var use24Hour: Bool
    public var sayAMPM: Bool
    public var compass: CompassStyle
    public var distanceMeasure: DistanceMeasure
    public var hailStyle: HailStyle
    public var sayThreatBasis: Bool         // "indicated by radar" / "observed"
    public var maxCities: Int
    public var maxCounties: Int
    /// Distances under this many miles are spoken as "less than N miles" / "nearby".
    public var roundDistancesTo: Int

    public init(issuedAgoMinMinutes: Int = 3, issuedAgoMaxMinutes: Int = 180, expiresRelative: Bool = true, expiresClock: Bool = true, use24Hour: Bool = false,
                sayAMPM: Bool = false, compass: CompassStyle = .eight, distanceMeasure: DistanceMeasure = .nearestEdge,
                hailStyle: HailStyle = .inchesAndObject, sayThreatBasis: Bool = true, maxCities: Int = 5, maxCounties: Int = 4,
                roundDistancesTo: Int = 1) {
        self.issuedAgoMinMinutes = issuedAgoMinMinutes
        self.issuedAgoMaxMinutes = issuedAgoMaxMinutes
        self.expiresRelative = expiresRelative
        self.expiresClock = expiresClock
        self.use24Hour = use24Hour
        self.sayAMPM = sayAMPM
        self.compass = compass
        self.distanceMeasure = distanceMeasure
        self.hailStyle = hailStyle
        self.sayThreatBasis = sayThreatBasis
        self.maxCities = maxCities
        self.maxCounties = maxCounties
        self.roundDistancesTo = roundDistancesTo
    }
}

/// What kinds of changes to existing alerts get announced.
public struct UpdateSettings: Codable, Hashable, Sendable {
    public var threatChanges: Bool          // hail/wind size, tornado observed, damage tags, PDS/emergency
    public var extensions: Bool
    public var areaReduced: Bool
    public var areaReducedMinPercent: Int
    public var areaExpanded: Bool
    public var cancellations: Bool
    public var cancelReason: Bool           // read why it was cancelled ("the storm has weakened...")
    public var expirations: Bool
    public var routineUpdates: Bool         // updates with no meaningful change
    public var cameIntoRange: Bool          // an existing alert is now within your distance (you moved / it moved)
    public var wentOutOfRange: Bool
    public var enteredWarning: Bool         // you drove into a warning polygon
    public var leftWarning: Bool
    public var enteredWarningDetails: Bool  // include threats + expiration when entering
    public var fullMessageOnUpgrade: Bool   // re-read the whole alert when it gets more dangerous

    public init(threatChanges: Bool = true, extensions: Bool = true, areaReduced: Bool = true, areaReducedMinPercent: Int = 20,
                areaExpanded: Bool = true, cancellations: Bool = true, cancelReason: Bool = true, expirations: Bool = true,
                routineUpdates: Bool = false, cameIntoRange: Bool = true, wentOutOfRange: Bool = false, enteredWarning: Bool = true,
                leftWarning: Bool = true, enteredWarningDetails: Bool = true, fullMessageOnUpgrade: Bool = true) {
        self.threatChanges = threatChanges
        self.extensions = extensions
        self.areaReduced = areaReduced
        self.areaReducedMinPercent = areaReducedMinPercent
        self.areaExpanded = areaExpanded
        self.cancellations = cancellations
        self.cancelReason = cancelReason
        self.expirations = expirations
        self.routineUpdates = routineUpdates
        self.cameIntoRange = cameIntoRange
        self.wentOutOfRange = wentOutOfRange
        self.enteredWarning = enteredWarning
        self.leftWarning = leftWarning
        self.enteredWarningDetails = enteredWarningDetails
        self.fullMessageOnUpgrade = fullMessageOnUpgrade
    }
}

/// "You are in the path" alerts computed from the NWS storm motion.
public struct PathSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Risk index 1-5 a storm must reach (see `RiskIndex`).
    public var minimumRisk: Int
    /// Announce when the arrival estimate first drops below each of these (minutes).
    public var leadTimesMinutes: [Int]
    /// How far either side of the storm track counts as "in the path".
    public var pathHalfWidthMiles: Double
    /// Only warn when you are inside the warning polygon (otherwise extrapolate beyond it).
    public var onlyInsideWarning: Bool
    public var mode: AnnounceMode
    public var tone: ToneID
    public var priority: Int

    public init(enabled: Bool = true, minimumRisk: Int = 3, leadTimesMinutes: [Int] = [30, 15, 5], pathHalfWidthMiles: Double = 4,
                onlyInsideWarning: Bool = false, mode: AnnounceMode = .toneThenSpeak, tone: ToneID = .alarm, priority: Int = 8) {
        self.enabled = enabled
        self.minimumRisk = minimumRisk
        self.leadTimesMinutes = leadTimesMinutes
        self.pathHalfWidthMiles = pathHalfWidthMiles
        self.onlyInsideWarning = onlyInsideWarning
        self.mode = mode
        self.tone = tone
        self.priority = priority
    }
}

/// Storm report categories (normalized across NWS LSR, SpotterNetwork, mPING).
public enum ReportCategory: String, Codable, CaseIterable, Sendable {
    case tornado, funnelCloud, wallCloud, hail, windGust, windDamage, flashFlood, flood, heavyRain, snow, other

    public var label: String {
        switch self {
        case .tornado: return "Tornado"
        case .funnelCloud: return "Funnel cloud"
        case .wallCloud: return "Wall cloud / rotation"
        case .hail: return "Hail"
        case .windGust: return "Measured/estimated wind gust"
        case .windDamage: return "Wind damage"
        case .flashFlood: return "Flash flood"
        case .flood: return "Flood"
        case .heavyRain: return "Heavy rain"
        case .snow: return "Snow / ice"
        case .other: return "Other"
        }
    }
}

public enum ReportSource: String, Codable, CaseIterable, Sendable {
    case nwsLSR, spotterNetwork, mping

    public var label: String {
        switch self {
        case .nwsLSR: return "NWS Local Storm Report"
        case .spotterNetwork: return "SpotterNetwork"
        case .mping: return "mPING"
        }
    }

    public var spoken: String {
        switch self {
        case .nwsLSR: return "N W S storm report"
        case .spotterNetwork: return "Spotter Network report"
        case .mping: return "M ping report"
        }
    }
}

public struct ReportRule: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var mode: AnnounceMode
    public var tone: ToneID
    /// Hail: inches; wind gust: mph; others ignored. 0 = any.
    public var minMagnitude: Double
    public var priority: Int

    public init(enabled: Bool = true, mode: AnnounceMode = .speak, tone: ToneID = .blip, minMagnitude: Double = 0, priority: Int = 4) {
        self.enabled = enabled
        self.mode = mode
        self.tone = tone
        self.minMagnitude = minMagnitude
        self.priority = priority
    }
}

public struct ReportSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var sources: [String: Bool]          // ReportSource.rawValue -> on/off
    public var maxDistanceMiles: Double
    /// Ignore reports whose event happened more than this many minutes ago.
    public var maxAgeMinutes: Int
    /// If a report was released this many minutes after it happened, say when it actually happened.
    public var delayedNoteMinutes: Int
    public var sayReporter: Bool                 // "reported by a trained spotter"
    public var sayRemarks: Bool
    public var saySource: Bool                   // "SpotterNetwork report"
    public var categories: [String: ReportRule]  // ReportCategory.rawValue -> rule

    public init(enabled: Bool = true, sources: [String: Bool] = [ReportSource.nwsLSR.rawValue: true, ReportSource.spotterNetwork.rawValue: true, ReportSource.mping.rawValue: false],
                maxDistanceMiles: Double = 30, maxAgeMinutes: Int = 45, delayedNoteMinutes: Int = 10, sayReporter: Bool = true,
                sayRemarks: Bool = false, saySource: Bool = true, categories: [String: ReportRule] = ReportSettings.defaultCategories) {
        self.enabled = enabled
        self.sources = sources
        self.maxDistanceMiles = maxDistanceMiles
        self.maxAgeMinutes = maxAgeMinutes
        self.delayedNoteMinutes = delayedNoteMinutes
        self.sayReporter = sayReporter
        self.sayRemarks = sayRemarks
        self.saySource = saySource
        self.categories = categories
    }

    public static let defaultCategories: [String: ReportRule] = [
        ReportCategory.tornado.rawValue: ReportRule(mode: .toneThenSpeak, tone: .siren, priority: 8),
        ReportCategory.funnelCloud.rawValue: ReportRule(mode: .speak, tone: .doubleBeep, priority: 6),
        ReportCategory.wallCloud.rawValue: ReportRule(mode: .speak, tone: .doubleBeep, priority: 5),
        ReportCategory.hail.rawValue: ReportRule(mode: .speak, tone: .blip, minMagnitude: 1.0, priority: 4),
        ReportCategory.windGust.rawValue: ReportRule(mode: .speak, tone: .blip, minMagnitude: 58, priority: 4),
        ReportCategory.windDamage.rawValue: ReportRule(mode: .speak, tone: .blip, priority: 4),
        ReportCategory.flashFlood.rawValue: ReportRule(mode: .speak, tone: .blip, priority: 4),
        ReportCategory.flood.rawValue: ReportRule(enabled: false, mode: .notifyOnly, priority: 2),
        ReportCategory.heavyRain.rawValue: ReportRule(enabled: false, mode: .notifyOnly, priority: 1),
        ReportCategory.snow.rawValue: ReportRule(enabled: false, mode: .notifyOnly, priority: 1),
        ReportCategory.other.rawValue: ReportRule(enabled: false, mode: .notifyOnly, priority: 1),
    ]

    public func rule(for c: ReportCategory) -> ReportRule {
        categories[c.rawValue] ?? ReportSettings.defaultCategories[c.rawValue] ?? ReportRule(enabled: false)
    }

    public func sourceEnabled(_ s: ReportSource) -> Bool { sources[s.rawValue] ?? (s != .mping) }
}

/// SPC convective outlook risk categories.
public enum OutlookCategory: String, Codable, CaseIterable, Comparable, Sendable {
    case none = "NONE", tstm = "TSTM", mrgl = "MRGL", slgt = "SLGT", enh = "ENH", mdt = "MDT", high = "HIGH"

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: OutlookCategory, b: OutlookCategory) -> Bool { a.rank < b.rank }

    public var spoken: String {
        switch self {
        case .none: return "no thunderstorm risk"
        case .tstm: return "general thunderstorms"
        case .mrgl: return "a marginal risk"
        case .slgt: return "a slight risk"
        case .enh: return "an enhanced risk"
        case .mdt: return "a moderate risk"
        case .high: return "a high risk"
        }
    }

    public var label: String {
        switch self {
        case .none: return "None"
        case .tstm: return "General thunder"
        case .mrgl: return "Marginal (1)"
        case .slgt: return "Slight (2)"
        case .enh: return "Enhanced (3)"
        case .mdt: return "Moderate (4)"
        case .high: return "High (5)"
        }
    }
}

public struct SPCSettings: Codable, Hashable, Sendable {
    // Mesoscale discussions
    public var mdEnabled: Bool
    public var mdNationwide: Bool              // announce every MD; otherwise only within mdMaxDistanceMiles
    public var mdMaxDistanceMiles: Double
    public var mdMode: AnnounceMode
    public var mdTone: ToneID
    public var mdPriority: Int
    public var mdReadSummary: Bool             // automatically read the SUMMARY after announcing
    // Watches (SPC watch issuance, nationwide)
    public var watchEnabled: Bool
    public var watchMode: AnnounceMode
    public var watchTone: ToneID
    public var watchPriority: Int
    public var watchReadThreats: Bool
    // Convective outlooks
    public var outlookEnabled: Bool
    public var outlookDays: [Int]
    /// Announce only if the highest risk anywhere is at least this.
    public var outlookMinimumRisk: OutlookCategory
    public var outlookMode: AnnounceMode
    public var outlookTone: ToneID
    public var outlookPriority: Int
    public var outlookSayMyRisk: Bool
    public var outlookReadSummary: Bool

    public init(mdEnabled: Bool = true, mdNationwide: Bool = true, mdMaxDistanceMiles: Double = 250, mdMode: AnnounceMode = .toneThenSpeak,
                mdTone: ToneID = .chimeUp, mdPriority: Int = 4, mdReadSummary: Bool = false, watchEnabled: Bool = true,
                watchMode: AnnounceMode = .toneThenSpeak, watchTone: ToneID = .chimeUp, watchPriority: Int = 6, watchReadThreats: Bool = true,
                outlookEnabled: Bool = true, outlookDays: [Int] = [1, 2, 3], outlookMinimumRisk: OutlookCategory = .mrgl,
                outlookMode: AnnounceMode = .speak, outlookTone: ToneID = .chimeDown, outlookPriority: Int = 2, outlookSayMyRisk: Bool = true,
                outlookReadSummary: Bool = false) {
        self.mdEnabled = mdEnabled
        self.mdNationwide = mdNationwide
        self.mdMaxDistanceMiles = mdMaxDistanceMiles
        self.mdMode = mdMode
        self.mdTone = mdTone
        self.mdPriority = mdPriority
        self.mdReadSummary = mdReadSummary
        self.watchEnabled = watchEnabled
        self.watchMode = watchMode
        self.watchTone = watchTone
        self.watchPriority = watchPriority
        self.watchReadThreats = watchReadThreats
        self.outlookEnabled = outlookEnabled
        self.outlookDays = outlookDays
        self.outlookMinimumRisk = outlookMinimumRisk
        self.outlookMode = outlookMode
        self.outlookTone = outlookTone
        self.outlookPriority = outlookPriority
        self.outlookSayMyRisk = outlookSayMyRisk
        self.outlookReadSummary = outlookReadSummary
    }
}

public struct AFDSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Include the NWS office that covers your location.
    public var includeLocalOffice: Bool
    /// Extra offices to follow, e.g. ["OUN", "ICT"].
    public var extraOffices: [String]
    public var mode: AnnounceMode
    public var tone: ToneID
    public var priority: Int
    /// Sections read automatically when a new AFD comes out (e.g. ["KEY MESSAGES"]). Empty = just announce it.
    public var readSectionsOnIssue: [String]
    /// Sections read when you press "Read AFD".
    public var readSectionsOnDemand: [String]

    public init(enabled: Bool = true, includeLocalOffice: Bool = true, extraOffices: [String] = [], mode: AnnounceMode = .speak,
                tone: ToneID = .ping, priority: Int = 1, readSectionsOnIssue: [String] = [],
                readSectionsOnDemand: [String] = ["UPDATE", "KEY MESSAGES", "SYNOPSIS", "NEAR TERM", "SHORT TERM", "DISCUSSION"]) {
        self.enabled = enabled
        self.includeLocalOffice = includeLocalOffice
        self.extraOffices = extraOffices
        self.mode = mode
        self.tone = tone
        self.priority = priority
        self.readSectionsOnIssue = readSectionsOnIssue
        self.readSectionsOnDemand = readSectionsOnDemand
    }
}

public struct VoiceSettings: Codable, Hashable, Sendable {
    /// 0...1, iOS default speaking rate is 0.5.
    public var rate: Double
    /// 0.5...2.0
    public var pitch: Double
    public var volume: Double
    public var toneVolume: Double
    /// Empty = system default voice. Otherwise an AVSpeechSynthesisVoice identifier.
    public var voiceIdentifier: String
    /// Lower music/other audio while speaking.
    public var duckOtherAudio: Bool
    /// Pause podcasts / navigation voice while speaking.
    public var interruptSpokenAudio: Bool
    /// Seconds of silence between queued messages.
    public var gapSeconds: Double
    /// Custom sound files are cut off after this many seconds.
    public var customSoundMaxSeconds: Double

    public init(rate: Double = 0.52, pitch: Double = 1.0, volume: Double = 1.0, toneVolume: Double = 0.7, voiceIdentifier: String = "",
                duckOtherAudio: Bool = true, interruptSpokenAudio: Bool = true, gapSeconds: Double = 0.6, customSoundMaxSeconds: Double = 10) {
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.toneVolume = toneVolume
        self.voiceIdentifier = voiceIdentifier
        self.duckOtherAudio = duckOtherAudio
        self.interruptSpokenAudio = interruptSpokenAudio
        self.gapSeconds = gapSeconds
        self.customSoundMaxSeconds = customSoundMaxSeconds
    }
}

/// Which tags / situations are allowed to cut off whatever is currently being read.
public struct InterruptSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// A message must be at least this priority to interrupt anything.
    public var minimumPriority: Int
    /// ...and higher than the message being read by at least this much.
    public var minimumGap: Int
    /// Put the interrupted message back in the queue to be read afterwards.
    public var resumeInterrupted: Bool
    // Tag boosts (added to the product's priority, capped at 10)
    public var pdsBoost: Int
    public var emergencyAlwaysTop: Bool
    public var destructiveBoost: Int
    public var considerableBoost: Int
    public var observedTornadoBoost: Int

    public init(enabled: Bool = true, minimumPriority: Int = 7, minimumGap: Int = 2, resumeInterrupted: Bool = true, pdsBoost: Int = 2,
                emergencyAlwaysTop: Bool = true, destructiveBoost: Int = 1, considerableBoost: Int = 0, observedTornadoBoost: Int = 1) {
        self.enabled = enabled
        self.minimumPriority = minimumPriority
        self.minimumGap = minimumGap
        self.resumeInterrupted = resumeInterrupted
        self.pdsBoost = pdsBoost
        self.emergencyAlwaysTop = emergencyAlwaysTop
        self.destructiveBoost = destructiveBoost
        self.considerableBoost = considerableBoost
        self.observedTornadoBoost = observedTornadoBoost
    }
}

public enum LocationMode: String, Codable, CaseIterable, Sendable {
    case gps     // follow the phone's location
    case fixed   // a chosen point (home, a target town)

    public var label: String { self == .gps ? "Follow my location (GPS)" : "Fixed point" }
}

public enum AreaMode: String, Codable, CaseIterable, Sendable {
    case radius   // circle around the reference point
    case polygon  // a custom drawn polygon / box

    public var label: String { self == .radius ? "Radius" : "Custom polygon / box" }
}

public struct LocationSettings: Codable, Hashable, Sendable {
    public var mode: LocationMode
    public var fixedPoint: GeoPoint?
    public var fixedName: String
    public var areaMode: AreaMode
    public var radiusMiles: Double
    public var polygon: [GeoPoint]
    public var polygonName: String

    public init(mode: LocationMode = .gps, fixedPoint: GeoPoint? = nil, fixedName: String = "", areaMode: AreaMode = .radius,
                radiusMiles: Double = 60, polygon: [GeoPoint] = [], polygonName: String = "") {
        self.mode = mode
        self.fixedPoint = fixedPoint
        self.fixedName = fixedName
        self.areaMode = areaMode
        self.radiusMiles = radiusMiles
        self.polygon = polygon
        self.polygonName = polygonName
    }
}

// MARK: - Profile & app settings

public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var location: LocationSettings
    /// NWS event name ("Tornado Warning") -> rule.
    public var alertRules: [String: ProductRule]
    /// Used for NWS events not listed in `alertRules`.
    public var otherAlertsRule: ProductRule
    public var template: MessageTemplate
    public var phrasing: PhraseOptions
    public var updates: UpdateSettings
    public var path: PathSettings
    public var reports: ReportSettings
    public var spc: SPCSettings
    public var afd: AFDSettings
    public var voice: VoiceSettings
    public var interrupts: InterruptSettings
    /// Say a summary of what is active when monitoring starts / the profile changes.
    public var startupSummary: Bool

    public init(id: String = UUID().uuidString, name: String, location: LocationSettings = LocationSettings(),
                alertRules: [String: ProductRule] = ProductCatalog.defaultRules, otherAlertsRule: ProductRule = .disabled,
                template: MessageTemplate = .standard, phrasing: PhraseOptions = PhraseOptions(), updates: UpdateSettings = UpdateSettings(),
                path: PathSettings = PathSettings(), reports: ReportSettings = ReportSettings(), spc: SPCSettings = SPCSettings(),
                afd: AFDSettings = AFDSettings(), voice: VoiceSettings = VoiceSettings(), interrupts: InterruptSettings = InterruptSettings(),
                startupSummary: Bool = true) {
        self.id = id
        self.name = name
        self.location = location
        self.alertRules = alertRules
        self.otherAlertsRule = otherAlertsRule
        self.template = template
        self.phrasing = phrasing
        self.updates = updates
        self.path = path
        self.reports = reports
        self.spc = spc
        self.afd = afd
        self.voice = voice
        self.interrupts = interrupts
        self.startupSummary = startupSummary
    }

    public func rule(for event: String) -> ProductRule {
        alertRules[event] ?? otherAlertsRule
    }
}

/// Settings shared by all profiles.
public struct GeneralSettings: Codable, Hashable, Sendable {
    /// Put an email or website here; NWS asks API users to identify themselves.
    public var contactInfo: String
    public var mpingAPIKey: String
    public var alertPollSeconds: Int
    public var reportPollSeconds: Int
    public var productPollSeconds: Int
    public var afdPollSeconds: Int
    /// Limit NWS alert downloads to your state + neighbors (saves cellular data). Off = whole country.
    public var limitToNearbyStates: Bool
    public var postNotifications: Bool
    /// Play inaudible audio to keep the app alive in the background (useful with a fixed location).
    public var keepAliveAudio: Bool
    /// Keep the screen on while the Radio tab is open.
    public var keepScreenOn: Bool

    public init(contactInfo: String = "", mpingAPIKey: String = "", alertPollSeconds: Int = 30, reportPollSeconds: Int = 60,
                productPollSeconds: Int = 120, afdPollSeconds: Int = 300, limitToNearbyStates: Bool = true, postNotifications: Bool = true,
                keepAliveAudio: Bool = false, keepScreenOn: Bool = false) {
        self.contactInfo = contactInfo
        self.mpingAPIKey = mpingAPIKey
        self.alertPollSeconds = alertPollSeconds
        self.reportPollSeconds = reportPollSeconds
        self.productPollSeconds = productPollSeconds
        self.afdPollSeconds = afdPollSeconds
        self.limitToNearbyStates = limitToNearbyStates
        self.postNotifications = postNotifications
        self.keepAliveAudio = keepAliveAudio
        self.keepScreenOn = keepScreenOn
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var activeProfileID: String
    public var profiles: [Profile]
    public var general: GeneralSettings

    public init(schemaVersion: Int = AppSettings.currentSchemaVersion, activeProfileID: String, profiles: [Profile], general: GeneralSettings = GeneralSettings()) {
        self.schemaVersion = schemaVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.general = general
    }

    public var activeProfile: Profile {
        get { profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first ?? Profile.chase }
        set {
            if let i = profiles.firstIndex(where: { $0.id == newValue.id }) { profiles[i] = newValue }
            else { profiles.append(newValue) }
        }
    }

    public static var defaults: AppSettings {
        let profiles = [Profile.chase, Profile.home, Profile.quiet, Profile.overnight]
        return AppSettings(activeProfileID: profiles[0].id, profiles: profiles)
    }

    public mutating func normalize() {
        if profiles.isEmpty { profiles = AppSettings.defaults.profiles }
        if !profiles.contains(where: { $0.id == activeProfileID }) { activeProfileID = profiles[0].id }
        for i in profiles.indices { profiles[i].template.normalize() }
    }
}
