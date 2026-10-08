import Foundation

/// A storm report from any source, normalized.
public struct StormReport: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var source: ReportSource
    public var category: ReportCategory
    /// What was reported, lowercased for speech ("hail", "tornado", "thunderstorm wind damage").
    public var typeText: String
    public var magnitude: Double?
    public var unit: String?
    /// true = measured, false = estimated, nil = unknown.
    public var measured: Bool?
    /// Who reported it ("Trained Spotter", "NWS Employee", a SpotterNetwork name...).
    public var reporter: String?
    /// "2 ENE Mcintyre"
    public var place: String?
    public var county: String?
    public var state: String?
    public var remark: String?
    public var point: GeoPoint
    /// When the event happened.
    public var eventTime: Date
    /// When the report was released (LSR product time). nil if the source doesn't say.
    public var releasedTime: Date?
    public var office: String?

    public init(id: String, source: ReportSource, category: ReportCategory, typeText: String, magnitude: Double? = nil, unit: String? = nil,
                measured: Bool? = nil, reporter: String? = nil, place: String? = nil, county: String? = nil, state: String? = nil,
                remark: String? = nil, point: GeoPoint, eventTime: Date, releasedTime: Date? = nil, office: String? = nil) {
        self.id = id
        self.source = source
        self.category = category
        self.typeText = typeText
        self.magnitude = magnitude
        self.unit = unit
        self.measured = measured
        self.reporter = reporter
        self.place = place
        self.county = county
        self.state = state
        self.remark = remark
        self.point = point
        self.eventTime = eventTime
        self.releasedTime = releasedTime
        self.office = office
    }

    /// Minutes between the event and its release (nil when unknown).
    public var delayMinutes: Int? {
        releasedTime.map { Spoken.minutesBetween(eventTime, $0) }
    }

    public var webLink: URL? {
        switch source {
        case .nwsLSR:
            return URL(string: "https://mesonet.agron.iastate.edu/lsr/")
        case .spotterNetwork:
            return URL(string: "https://www.spotternetwork.org/")
        case .mping:
            return URL(string: "https://mping.ou.edu/")
        }
    }
}

public enum ReportParsers {
    // MARK: NWS LSR via Iowa Environmental Mesonet GeoJSON

    struct LSRCollection: Decodable { var features: [LSRFeature] }
    struct LSRFeature: Decodable {
        var properties: LSRProps
        var geometry: GeoJSONGeometry?
    }
    struct LSRProps: Decodable {
        var wfo: String?
        var typetext: String?
        var magnitude: LooseString?
        var magf: Double?
        var unit: String?
        var qualifier: String?
        var city: String?
        var county: String?
        var state: String?
        var source: String?
        var remark: String?
        var valid: String?
        var lat: Double?
        var lon: Double?
        var product_id: String?
    }

    public static func lsrCategory(_ type: String) -> ReportCategory {
        let t = type.uppercased()
        if t.contains("TORNADO") || t.contains("WATERSPOUT") { return .tornado }
        if t.contains("FUNNEL") { return .funnelCloud }
        if t.contains("WALL CLOUD") { return .wallCloud }
        if t.contains("HAIL") { return .hail }
        if t.contains("WND GST") || t.contains("WIND GUST") || t.contains("MARINE TSTM WIND") { return .windGust }
        if t.contains("WND DMG") || t.contains("WIND DAMAGE") || t == "DAMAGE" || t.contains("DOWNBURST") { return .windDamage }
        if t.contains("FLASH FLOOD") { return .flashFlood }
        if t.contains("FLOOD") { return .flood }
        if t.contains("RAIN") { return .heavyRain }
        if t.contains("SNOW") || t.contains("ICE") || t.contains("SLEET") || t.contains("FREEZING") || t.contains("BLIZZARD") { return .snow }
        return .other
    }

    static func lsrSpokenType(_ t: String) -> String {
        let map: [String: String] = [
            "TSTM WND GST": "thunderstorm wind gust", "NON-TSTM WND GST": "non-thunderstorm wind gust",
            "TSTM WND DMG": "thunderstorm wind damage", "NON-TSTM WND DMG": "wind damage",
            "MARINE TSTM WIND": "marine thunderstorm wind", "FUNNEL CLOUD": "funnel cloud",
        ]
        return map[t.uppercased()] ?? t.lowercased()
    }

    public static func parseLSR(_ data: Data) throws -> [StormReport] {
        let col = try JSONDecoder().decode(LSRCollection.self, from: data)
        return col.features.compactMap { f in
            let p = f.properties
            guard let type = p.typetext, let valid = WxDate.iso(p.valid) else { return nil }
            let pt = f.geometry?.point ?? (p.lat.flatMap { la in p.lon.map { GeoPoint(lat: la, lon: $0) } })
            guard let point = pt else { return nil }
            let released = p.product_id.flatMap { WxDate.compact($0) }
            let mag = p.magf ?? p.magnitude?.value.flatMap(Double.init)
            let id = "LSR|\(p.product_id ?? "")|\(p.valid ?? "")|\(type)|\(point.lat),\(point.lon)"
            return StormReport(
                id: id, source: .nwsLSR, category: lsrCategory(type), typeText: lsrSpokenType(type),
                magnitude: (mag ?? 0) > 0 ? mag : nil, unit: p.unit,
                measured: p.qualifier.map { $0.uppercased() == "M" },
                reporter: p.source, place: p.city, county: p.county, state: p.state, remark: p.remark,
                point: point, eventTime: valid, releasedTime: released, office: p.wfo)
        }
    }

    // MARK: SpotterNetwork placefile (https://www.spotternetwork.org/feeds/reports.txt)

    public static func spotterNetworkCategory(_ type: String) -> ReportCategory {
        let t = type.lowercased()
        if t.contains("tornado") { return .tornado }
        if t.contains("funnel") { return .funnelCloud }
        if t.contains("wall cloud") || t.contains("rotation") { return .wallCloud }
        if t.contains("hail") { return .hail }
        if t.contains("damage") { return .windDamage }
        if t.contains("wind") { return .windGust }
        if t.contains("flash flood") { return .flashFlood }
        if t.contains("flood") { return .flood }
        if t.contains("rain") { return .heavyRain }
        if t.contains("snow") || t.contains("ice") || t.contains("freezing") { return .snow }
        return .other
    }

    public static func parseSpotterNetwork(_ text: String) -> [StormReport] {
        var out: [StormReport] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("icon:") else { continue }
            let body = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let q1 = body.firstIndex(of: "\"") else { continue }
            let nums = body[..<q1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard nums.count >= 2, let lat = Double(nums[0]), let lon = Double(nums[1]) else { continue }
            var label = String(body[body.index(after: q1)...])
            if label.hasSuffix("\"") { label.removeLast() }
            let lines = label.components(separatedBy: "\\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var fields: [String: String] = [:]
            var typeLine: String?
            for l in lines {
                if let c = l.range(of: ":") {
                    let k = l[..<c.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = l[c.upperBound...].trimmingCharacters(in: .whitespaces)
                    fields[k] = v
                } else if typeLine == nil, !l.isEmpty {
                    typeLine = l
                }
            }
            guard let type = typeLine, let timeStr = fields["time"], let time = WxDate.spaced(timeStr) else { continue }
            let cat = spotterNetworkCategory(type)
            var mag: Double?
            var unit: String?
            if let size = fields["size"] ?? fields["hail size"], let v = firstNumber(size) { mag = v; unit = "Inch" }
            if let w = fields["wind"] ?? fields["wind speed"] ?? fields["speed"] ?? fields["gust"], let v = firstNumber(w) { mag = v; unit = "MPH" }
            let notes = fields["notes"] ?? fields["comments"]
            if mag == nil, let n = notes {
                if cat == .hail, let v = firstNumber(n), v < 8 { mag = v; unit = "Inch" }
                if cat == .windGust, let v = firstNumber(n), v >= 30 { mag = v; unit = "MPH" }
            }
            out.append(StormReport(
                id: "SN|\(lat),\(lon)|\(timeStr)|\(type)", source: .spotterNetwork, category: cat, typeText: type.lowercased(),
                magnitude: mag, unit: unit, reporter: fields["reported by"], remark: notes?.isEmpty == true ? nil : notes,
                point: GeoPoint(lat: lat, lon: lon), eventTime: time, releasedTime: nil))
        }
        return out
    }

    static func firstNumber(_ s: String) -> Double? {
        var current = ""
        for ch in s {
            if ch.isNumber || (ch == "." && !current.contains(".")) { current.append(ch) }
            else if !current.isEmpty { break }
        }
        if current == "." { return nil }
        return Double(current)
    }

    // MARK: mPING (https://mping.ou.edu/mping/api/v2/reports, needs an API token)

    struct MPingPage: Decodable {
        var results: [MPingReport]?
        var next: String?
    }
    struct MPingReport: Decodable {
        var id: Int?
        var obtime: String?
        var category: String?
        var description: String?
        var geom: GeoJSONGeometry?
    }

    public static func mpingCategory(_ category: String, _ description: String) -> ReportCategory {
        let c = category.lowercased(), d = description.lowercased()
        if c.contains("tornado") { return d.contains("funnel") ? .funnelCloud : .tornado }
        if c.contains("hail") { return .hail }
        if c.contains("wind") { return .windDamage }
        if c.contains("flood") { return d.contains("flash") ? .flashFlood : .flood }
        if c.contains("rain") || c.contains("snow") {
            return d.contains("snow") || d.contains("ice") || d.contains("sleet") || d.contains("freezing") ? .snow : .heavyRain
        }
        return .other
    }

    public static func parseMPing(_ data: Data) throws -> [StormReport] {
        let page = try JSONDecoder().decode(MPingPage.self, from: data)
        return (page.results ?? []).compactMap { r in
            guard let cat = r.category, let t = WxDate.iso(r.obtime), let p = r.geom?.point else { return nil }
            let desc = r.description ?? ""
            let category = mpingCategory(cat, desc)
            var mag: Double?
            var unit: String?
            if category == .hail, let open = desc.firstIndex(of: "("), let v = firstNumber(String(desc[open...])) { mag = v; unit = "Inch" }
            return StormReport(
                id: "MP|\(r.id.map(String.init) ?? "\(t)|\(p.lat),\(p.lon)")", source: .mping, category: category,
                typeText: desc.isEmpty ? cat.lowercased() : "\(cat.lowercased()), \(desc.lowercased())",
                magnitude: mag, unit: unit, reporter: "mPING user", point: p, eventTime: t, releasedTime: nil)
        }
    }
}

// MARK: - Report wording

public struct ReportPhraser {
    public var settings: ReportSettings
    public var phrasing: PhraseOptions

    public init(settings: ReportSettings, phrasing: PhraseOptions) {
        self.settings = settings
        self.phrasing = phrasing
    }

    static let reporterWords: [String: String] = [
        "trained spotter": "a trained spotter", "public": "the public", "nws employee": "an N W S employee",
        "emergency mngr": "emergency management", "emergency manager": "emergency management", "law enforcement": "law enforcement",
        "storm chaser": "a storm chaser", "broadcast media": "broadcast media", "mesonet": "a mesonet station",
        "asos": "an A S O S station", "awos": "an A W O S station", "asos/awos": "an airport weather station",
        "official nws obse": "an official N W S observer", "official nws obs": "an official N W S observer",
        "911 call center": "a 9 1 1 call center", "social media": "social media", "amateur radio": "amateur radio",
        "fire dept/rescue": "fire and rescue", "co-op observer": "a co-op observer", "cocorahs": "a CoCoRaHS observer",
        "other federal": "a federal agency", "nws storm survey": "an N W S storm survey", "buoy": "a buoy",
        "mping user": "an M ping user", "dept of highways": "the highway department",
    ]

    public func reporterPhrase(_ r: StormReport) -> String? {
        guard let rep = r.reporter, !rep.isEmpty else { return nil }
        if r.source == .spotterNetwork { return "spotter \(rep)" }
        return Self.reporterWords[rep.lowercased()] ?? rep.lowercased()
    }

    func whatPhrase(_ r: StormReport) -> String {
        switch r.category {
        case .hail:
            if let m = r.magnitude { return Spoken.hail(m, style: phrasing.hailStyle) }
            return "hail"
        case .windGust:
            if let m = r.magnitude {
                let unitIsKnots = (r.unit ?? "").uppercased().contains("KT")
                let mph = Int((unitIsKnots ? m * Geo.mphPerKnot : m).rounded())
                let q = r.measured.map { $0 ? "measured" : "estimated" }
                return "\(q.map { "a \($0) " } ?? "a ")\(mph) mile per hour \(r.typeText.contains("non-thunderstorm") ? "wind gust" : "thunderstorm wind gust")"
            }
            return "a \(r.typeText)"
        case .tornado:
            return r.typeText.contains("waterspout") ? "a waterspout" : "a tornado"
        case .funnelCloud: return "a funnel cloud"
        case .wallCloud: return r.typeText.contains("rotat") ? "a rotating wall cloud" : "a wall cloud"
        case .heavyRain, .snow:
            if let m = r.magnitude { return "\(Spoken.inches(m)) of \(r.typeText)" }
            return r.typeText
        default:
            return r.typeText
        }
    }

    public func title(_ r: StormReport, from ref: GeoPoint?) -> String {
        var t = r.category.label
        if r.category == .hail, let m = r.magnitude { t = String(format: "%.2f\" hail", m) }
        if r.category == .windGust, let m = r.magnitude { t = "\(Int(m)) mph gust" }
        if let ref = ref {
            let d = Geo.distanceMiles(ref, r.point)
            t += " · \(Int(d.rounded())) mi \(Compass.abbreviation(for: Geo.bearing(from: ref, to: r.point)))"
        }
        return t
    }

    public func compose(_ r: StormReport, from ref: GeoPoint?, now: Date, timeZone: TimeZone = .current) -> String {
        var s: [String] = []
        var lead = settings.saySource ? "\(r.source.spoken): " : ""
        lead += whatPhrase(r)
        if settings.sayReporter, let who = reporterPhrase(r) { lead += ", reported by \(who)" }
        if let ref = ref {
            let d = Geo.distanceMiles(ref, r.point)
            if d < 1 { lead += ", at your location" } else {
                lead += ", \(Spoken.distance(d)) to the \(Compass.name(for: Geo.bearing(from: ref, to: r.point), style: phrasing.compass))"
            }
        }
        if let place = r.place, !place.isEmpty { lead += ", \(Spoken.lsrPlace(place))" }
        s.append(lead)

        let ago = Spoken.minutesBetween(r.eventTime, now)
        let clock = Spoken.clock(r.eventTime, use24Hour: phrasing.use24Hour, sayAMPM: phrasing.sayAMPM, timeZone: timeZone)
        if let delay = r.delayMinutes, delay >= settings.delayedNoteMinutes {
            s.append("Delayed report. It happened at \(clock), \(Spoken.duration(minutes: max(ago, 0))) ago")
        } else if ago >= 5 {
            s.append("It happened \(Spoken.duration(minutes: ago)) ago, at \(clock)")
        }
        if settings.sayRemarks, let rem = r.remark, !rem.isEmpty { s.append(Spoken.normalizeForSpeech(rem)) }
        return Spoken.joinSentences(s)
    }
}
