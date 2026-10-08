import Foundation

/// How a threat was determined, from the IBW tags (`hailThreat`, `windThreat`, `tornadoDetection`...).
public enum ThreatBasis: String, Codable, Sendable {
    case radarIndicated = "RADAR INDICATED"
    case observed = "OBSERVED"
    case possible = "POSSIBLE"
    case radarConfirmed = "RADAR CONFIRMED"
    case unknown

    public init(tag: String?) {
        guard let t = tag?.uppercased().trimmingCharacters(in: .whitespaces), !t.isEmpty else {
            self = .unknown
            return
        }
        self = ThreatBasis(rawValue: t) ?? (t.contains("OBSERV") ? .observed : t.contains("RADAR") ? .radarIndicated : .unknown)
    }
}

/// Damage threat tags (CONSIDERABLE / DESTRUCTIVE / CATASTROPHIC).
public enum DamageTag: String, Codable, Comparable, Sendable {
    case none = ""
    case base = "BASE"
    case considerable = "CONSIDERABLE"
    case destructive = "DESTRUCTIVE"
    case catastrophic = "CATASTROPHIC"

    public init(tag: String?) {
        self = DamageTag(rawValue: tag?.uppercased().trimmingCharacters(in: .whitespaces) ?? "") ?? .none
    }

    var rank: Int {
        switch self {
        case .none, .base: return 0
        case .considerable: return 1
        case .destructive: return 2
        case .catastrophic: return 3
        }
    }

    public static func < (a: DamageTag, b: DamageTag) -> Bool { a.rank < b.rank }

    public var spoken: String { rawValue.lowercased() }
}

/// Storm location and motion from `eventMotionDescription`
/// e.g. `2026-10-04T21:20:00-00:00...storm...221DEG...6KT...30.23,-87.93`.
public struct StormMotion: Codable, Hashable, Sendable {
    public var time: Date
    /// Direction the storm is coming FROM, in degrees (meteorological convention).
    public var fromDegrees: Double
    public var speedKnots: Double
    /// Storm location(s) at `time`; several points describe a line of storms.
    public var points: [GeoPoint]

    public var headingDegrees: Double { Geo.normalizeDegrees(fromDegrees + 180) }
    public var speedMPH: Double { speedKnots * Geo.mphPerKnot }

    public init(time: Date, fromDegrees: Double, speedKnots: Double, points: [GeoPoint]) {
        self.time = time
        self.fromDegrees = fromDegrees
        self.speedKnots = speedKnots
        self.points = points
    }

    public static func parse(_ raw: String) -> StormMotion? {
        let parts = raw.components(separatedBy: "...")
        guard parts.count >= 5, let time = WxDate.iso(parts[0]) else { return nil }
        let deg = Double(parts[2].replacingOccurrences(of: "DEG", with: "")) ?? 0
        let kt = Double(parts[3].replacingOccurrences(of: "KT", with: "")) ?? 0
        let pts = parts[4].split(separator: " ").compactMap { pair -> GeoPoint? in
            let ll = pair.split(separator: ",")
            guard ll.count == 2, let la = Double(ll[0]), let lo = Double(ll[1]) else { return nil }
            return GeoPoint(lat: la, lon: lo)
        }
        guard !pts.isEmpty else { return nil }
        return StormMotion(time: time, fromDegrees: deg, speedKnots: kt, points: pts)
    }

    /// Storm points extrapolated to `date`.
    public func positions(at date: Date) -> [GeoPoint] {
        let hours = date.timeIntervalSince(time) / 3600
        let miles = speedMPH * hours
        guard abs(miles) > 0.01 else { return points }
        return points.map { Geo.destination(from: $0, bearingDegrees: headingDegrees, miles: miles) }
    }
}

/// An NWS alert message (one CAP message from api.weather.gov).
public struct WeatherAlert: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var event: String
    public var messageType: String
    public var status: String
    public var sent: Date?
    public var effective: Date?
    public var onset: Date?
    public var expires: Date?
    public var ends: Date?
    public var severity: String
    public var certainty: String
    public var urgency: String
    public var senderName: String
    public var headline: String?
    public var nwsHeadline: String?
    public var description: String
    public var instruction: String?
    public var areaDesc: String
    public var ugc: [String]
    public var affectedZones: [String]
    public var references: [String]
    public var vtec: [VTEC]
    public var awipsID: String?
    public var geometry: GeoShape?
    /// True when `geometry` was filled in from zone/county outlines rather than a warning polygon.
    public var geometryFromZones: Bool = false

    // Impact-based warning details
    public var maxHailInches: Double?
    public var hailBasis: ThreatBasis = .unknown
    public var maxWindMPH: Int?
    public var windBasis: ThreatBasis = .unknown
    public var tornadoDetection: ThreatBasis = .unknown
    public var tornadoDamage: DamageTag = .none
    public var thunderstormDamage: DamageTag = .none
    public var flashFloodDetection: ThreatBasis = .unknown
    public var flashFloodDamage: DamageTag = .none
    public var waterspoutDetection: ThreatBasis = .unknown
    public var motion: StormMotion?

    public init(id: String, event: String) {
        self.id = id
        self.event = event
        self.messageType = "Alert"
        self.status = "Actual"
        self.severity = ""
        self.certainty = ""
        self.urgency = ""
        self.senderName = ""
        self.description = ""
        self.areaDesc = ""
        self.ugc = []
        self.affectedZones = []
        self.references = []
        self.vtec = []
    }

    /// The VTEC describing this event (ignores the UPG half of an upgrade pair).
    public var primaryVTEC: VTEC? {
        vtec.first(where: { $0.action != .upg }) ?? vtec.first
    }

    /// Stable key for the event this message belongs to (VTEC-based, falls back to the message id).
    public var eventKey: String { primaryVTEC?.eventKey ?? "ID:\(id)" }

    /// When the event ends: `ends`, VTEC end, then `expires`.
    public var endTime: Date? { ends ?? primaryVTEC?.end ?? expires }

    /// When the event was first issued (VTEC begin if known, else effective/sent).
    public var issuedTime: Date? { primaryVTEC?.begin ?? onset ?? effective ?? sent }

    public var officeName: String {
        senderName.replacingOccurrences(of: "NWS ", with: "")
    }

    // MARK: Text-derived details

    private var upperText: String { ((nwsHeadline ?? "") + "\n" + description).uppercased() }

    public var isTornadoEmergency: Bool { upperText.contains("TORNADO EMERGENCY") || tornadoDamage == .catastrophic }
    public var isFlashFloodEmergency: Bool { upperText.contains("FLASH FLOOD EMERGENCY") || (flashFloodDamage == .catastrophic && event.contains("Flash Flood")) }
    public var isPDS: Bool {
        upperText.contains("PARTICULARLY DANGEROUS SITUATION") || (event == "Tornado Warning" && tornadoDamage == .considerable)
    }
    public var isEmergency: Bool { isTornadoEmergency || isFlashFloodEmergency }

    /// The value after `SOURCE...` in the description, e.g. "Radar indicated rotation".
    public var sourceText: String? { Self.labeledLine("SOURCE", in: description) }

    /// SOURCE line prepared for speech: lowercased, "NWS" spelled out.
    public var spokenSource: String? {
        sourceText.map { src in
            var t = src.lowercased()
            if let re = try? NSRegularExpression(pattern: "\\bnws\\b") {
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "N W S")
            }
            return t
        }
    }

    /// The value after `HAZARD...`.
    public var hazardText: String? { Self.labeledLine("HAZARD", in: description) }

    /// Cities listed after "Locations impacted include..." (or similar phrasing).
    public var locationsImpacted: [String] {
        Self.parseLocations(description)
    }

    /// The first paragraph of the description, typically "At 420 PM CDT, a severe thunderstorm was located..."
    public var situationParagraph: String? {
        let paras = description.components(separatedBy: "\n\n")
        return paras.first(where: { $0.uppercased().hasPrefix("AT ") || $0.uppercased().hasPrefix("* AT ") })
            .map(Self.unwrap)
    }

    /// Link to a human-readable page for this alert.
    public var webLink: URL? {
        if let v = primaryVTEC {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let year = cal.component(.year, from: issuedTime ?? sent ?? Date())
            return URL(string: "https://mesonet.agron.iastate.edu/vtec/?wfo=\(v.office)&phenomena=\(v.phenomena)&significance=\(v.significance)&eventid=\(String(format: "%04d", v.eventNumber))&year=\(year)")
        }
        return URL(string: "https://api.weather.gov/alerts/\(id)")
    }

    static func labeledLine(_ label: String, in text: String) -> String? {
        guard let r = text.range(of: "\(label)...") else { return nil }
        let rest = text[r.upperBound...]
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
        var v = unwrap(String(rest[..<end]))
        if v.hasSuffix(".") { v.removeLast() }
        return v.isEmpty ? nil : v
    }

    static func unwrap(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseLocations(_ text: String) -> [String] {
        // e.g. "Locations impacted include...\nBrockport, Medina, and Albion."
        //      "* Some locations that will experience flash flooding include...\nFernandina Beach, Yulee and Amelia City."
        guard let re = try? NSRegularExpression(pattern: "locations?[^\\n]{0,60}?includes?\\.\\.\\.", options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return [] }
        let rest = text[r.upperBound...]
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
        var block = unwrap(String(rest[..<end]))
        if block.hasSuffix(".") { block.removeLast() }
        block = block.replacingOccurrences(of: ", and ", with: ", ").replacingOccurrences(of: " and ", with: ", ")
        return block.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 60 }
    }

    /// County/area names from `areaDesc` ("Tulsa, OK; Wagoner, OK" -> ["Tulsa", "Wagoner"]).
    public var areaNames: [String] {
        areaDesc.split(separator: ";").map { part in
            let s = part.trimmingCharacters(in: .whitespaces)
            if let comma = s.lastIndex(of: ","), s.distance(from: comma, to: s.endIndex) <= 4 {
                return String(s[..<comma])
            }
            return s
        }
    }
}

// MARK: - Decoding from api.weather.gov GeoJSON

struct NWSAlertCollection: Decodable {
    var features: [NWSAlertFeature]
}

struct NWSAlertFeature: Decodable {
    var id: String?
    var geometry: GeoJSONGeometry?
    var properties: Props

    struct Ref: Decodable { var identifier: String? }

    struct Props: Decodable {
        var id: String?
        var event: String?
        var messageType: String?
        var status: String?
        var sent: String?
        var effective: String?
        var onset: String?
        var expires: String?
        var ends: String?
        var severity: String?
        var certainty: String?
        var urgency: String?
        var senderName: String?
        var headline: String?
        var description: String?
        var instruction: String?
        var areaDesc: String?
        var geocode: [String: [String]]?
        var affectedZones: [String]?
        var references: [Ref]?
        var parameters: [String: StringOrArray]?
    }

    enum CodingKeys: String, CodingKey { case id, geometry, properties }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(String.self, forKey: .id)
        geometry = try? c.decodeIfPresent(GeoJSONGeometry.self, forKey: .geometry)
        properties = try c.decode(Props.self, forKey: .properties)
    }
}

public enum NWSAlertParser {
    public static func parseCollection(_ data: Data) throws -> [WeatherAlert] {
        let col = try JSONDecoder().decode(NWSAlertCollection.self, from: data)
        return col.features.compactMap(convert)
    }

    static func convert(_ f: NWSAlertFeature) -> WeatherAlert? {
        let p = f.properties
        guard let id = p.id ?? f.id, let event = p.event else { return nil }
        var a = WeatherAlert(id: id, event: event)
        a.messageType = p.messageType ?? "Alert"
        a.status = p.status ?? "Actual"
        a.sent = WxDate.iso(p.sent)
        a.effective = WxDate.iso(p.effective)
        a.onset = WxDate.iso(p.onset)
        a.expires = WxDate.iso(p.expires)
        a.ends = WxDate.iso(p.ends)
        a.severity = p.severity ?? ""
        a.certainty = p.certainty ?? ""
        a.urgency = p.urgency ?? ""
        a.senderName = p.senderName ?? ""
        a.headline = p.headline
        a.description = p.description ?? ""
        a.instruction = p.instruction
        a.areaDesc = p.areaDesc ?? ""
        a.ugc = p.geocode?["UGC"] ?? []
        a.affectedZones = p.affectedZones ?? []
        a.references = (p.references ?? []).compactMap { $0.identifier }
        a.geometry = f.geometry?.shape

        let params = p.parameters ?? [:]
        func first(_ k: String) -> String? { params[k]?.values.first }
        a.nwsHeadline = first("NWSheadline")
        a.awipsID = first("AWIPSidentifier")
        a.vtec = (params["VTEC"]?.values ?? []).compactMap(VTEC.parse)
        a.maxHailInches = parseHail(first("maxHailSize"))
        a.hailBasis = ThreatBasis(tag: first("hailThreat"))
        a.maxWindMPH = parseWind(first("maxWindGust"))
        a.windBasis = ThreatBasis(tag: first("windThreat"))
        a.tornadoDetection = ThreatBasis(tag: first("tornadoDetection"))
        a.tornadoDamage = DamageTag(tag: first("tornadoDamageThreat"))
        a.thunderstormDamage = DamageTag(tag: first("thunderstormDamageThreat"))
        a.flashFloodDetection = ThreatBasis(tag: first("flashFloodDetection"))
        a.flashFloodDamage = DamageTag(tag: first("flashFloodDamageThreat"))
        a.waterspoutDetection = ThreatBasis(tag: first("waterspoutDetection"))
        a.motion = first("eventMotionDescription").flatMap(StormMotion.parse)
        return a
    }

    /// "2.00" -> 2.0, "Up to .75" -> 0.75, "0.00" -> nil
    static func parseHail(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        let cleaned = s.uppercased().replacingOccurrences(of: "UP TO", with: "").replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v > 0 else { return nil }
        return v
    }

    /// "60 MPH" -> 60
    static func parseWind(_ s: String?) -> Int? {
        guard let s = s else { return nil }
        let digits = s.filter { $0.isNumber || $0 == "." }
        guard let v = Double(digits), v > 0 else { return nil }
        if s.uppercased().contains("KT") { return Int((v * Geo.mphPerKnot).rounded()) }
        return Int(v)
    }
}
