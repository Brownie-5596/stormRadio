import Foundation

enum SPCLinks {
    static func year(_ d: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.component(.year, from: d)
    }
}

/// Shared text helpers for NWS/SPC text products.
public enum ProductText {
    /// Value following "Label..." up to the next blank line, unwrapped.
    public static func field(_ label: String, in text: String) -> String? {
        guard let r = text.range(of: "\(label)...", options: .caseInsensitive) else { return nil }
        let rest = text[r.upperBound...]
        let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
        let v = WeatherAlert.unwrap(String(rest[..<end]))
        return v.isEmpty ? nil : v
    }

    /// Parses an SPC/NWS `LAT...LON` block, e.g. `28128331 28218317` -> (28.12, -83.31), (28.21, -83.17).
    public static func latLonPolygon(in text: String) -> [GeoPoint] {
        guard let r = text.range(of: "LAT...LON") else { return [] }
        var pts: [GeoPoint] = []
        let rest = text[r.upperBound...]
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            let tokens = line.split(separator: " ")
            if tokens.isEmpty { if !pts.isEmpty { break } else { continue } }
            var lineHadPoint = false
            for t in tokens where t.count == 8 && t.allSatisfy({ $0.isNumber }) {
                let lat = Double(t.prefix(4))! / 100
                var lon = Double(t.suffix(4))! / 100
                if lon < 50 { lon += 100 }
                pts.append(GeoPoint(lat: lat, lon: -lon))
                lineHadPoint = true
            }
            if !lineHadPoint && !pts.isEmpty { break }
        }
        if pts.count > 1, pts.first == pts.last { pts.removeLast() }
        return pts
    }

    /// Splits a product into the paragraph text with line breaks unwrapped.
    public static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map(WeatherAlert.unwrap).filter { !$0.isEmpty }
    }
}

// MARK: - Mesoscale discussion

public struct MesoscaleDiscussion: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var issued: Date
    public var areasAffected: String
    public var concerning: String
    public var watchProbability: Int?
    public var summary: String
    public var discussion: String
    public var polygon: [GeoPoint]
    public var peakTornado: String?
    public var peakWind: String?
    public var peakHail: String?
    public var rawText: String

    public var link: URL? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let year = cal.component(.year, from: issued)
        return URL(string: "https://www.spc.noaa.gov/products/md/\(year)/md\(String(format: "%04d", number)).html")
    }

    public var shape: GeoShape? { polygon.count >= 3 ? GeoShape(ring: polygon) : nil }

    /// SPC's graphic for this MD.
    public var imageURL: URL? {
        URL(string: "https://www.spc.noaa.gov/products/md/\(SPCLinks.year(issued))/mcd\(String(format: "%04d", number)).png")
    }

    public static func parse(_ text: String, id: String, issued: Date) -> MesoscaleDiscussion? {
        guard let r = text.range(of: "Mesoscale Discussion ", options: .caseInsensitive) else { return nil }
        let numStr = text[r.upperBound...].prefix(while: { $0.isNumber })
        guard let num = Int(numStr) else { return nil }
        let peak: (String) -> String? = { label in
            guard let rr = text.range(of: label) else { return nil }
            let line = text[rr.upperBound...].prefix(while: { $0 != "\n" })
            return line.trimmingCharacters(in: .whitespaces)
        }
        return MesoscaleDiscussion(
            id: id, number: num, issued: issued,
            areasAffected: ProductText.field("Areas affected", in: text) ?? "",
            concerning: ProductText.field("Concerning", in: text) ?? "",
            watchProbability: ProductText.field("Probability of Watch Issuance", in: text).flatMap { s in Int(s.prefix(while: { $0.isNumber })) },
            summary: ProductText.field("SUMMARY", in: text) ?? "",
            discussion: ProductText.field("DISCUSSION", in: text) ?? "",
            polygon: ProductText.latLonPolygon(in: text),
            peakTornado: peak("MOST PROBABLE PEAK TORNADO INTENSITY..."),
            peakWind: peak("MOST PROBABLE PEAK WIND GUST..."),
            peakHail: peak("MOST PROBABLE PEAK HAIL SIZE..."),
            rawText: text)
    }

    /// "Severe potential...Watch likely" -> "severe potential, watch likely"
    public var concerningSpoken: String {
        concerning.replacingOccurrences(of: "...", with: ", ").lowercased()
    }

    public func announcement(from ref: GeoPoint?, compass: CompassStyle, readSummary: Bool) -> String {
        var s = ["S P C Mesoscale Discussion \(number) for \(areasAffected.lowercased())"]
        if !concerning.isEmpty { s.append("Concerning \(concerningSpoken)") }
        if let p = watchProbability { s.append("Probability of watch issuance, \(p) percent") }
        if let ref = ref, let shape = shape, let d = Geo.distance(from: ref, to: shape) {
            if d.inside { s.append("Your location is inside the discussion area") }
            else { s.append("It is \(Spoken.distance(d.miles)) to your \(Compass.name(for: Geo.bearing(from: ref, to: d.nearest), style: compass))") }
        }
        if readSummary && !summary.isEmpty { s.append("Summary: \(Spoken.normalizeForSpeech(summary))") }
        return Spoken.joinSentences(s)
    }
}

// MARK: - SPC watch (SEL product)

public struct SPCWatch: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String          // "Tornado Watch" / "Severe Thunderstorm Watch"
    public var number: Int
    public var issued: Date
    public var isPDS: Bool
    public var areas: [String]       // "Central and Northern Oklahoma"
    public var effective: String     // "Effective this Monday afternoon and evening from 125 PM until 900 PM CDT."
    public var threats: [String]
    public var rawText: String

    public var link: URL? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return URL(string: "https://www.spc.noaa.gov/products/watch/\(cal.component(.year, from: issued))/ww\(String(format: "%04d", number)).html")
    }

    /// SPC's watch map with radar.
    public var imageURL: URL? {
        URL(string: "https://www.spc.noaa.gov/products/watch/\(SPCLinks.year(issued))/ww\(String(format: "%04d", number))_radar_big.gif")
    }

    public static func parse(_ text: String, id: String, issued: Date) -> SPCWatch? {
        let pattern = "(Tornado|Severe Thunderstorm) Watch Number (\\d+)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let tr = Range(m.range(at: 1), in: text), let nr = Range(m.range(at: 2), in: text),
              let num = Int(text[nr]) else { return nil }
        let type = text[tr].lowercased().contains("tornado") ? "Tornado Watch" : "Severe Thunderstorm Watch"
        let pds = text.uppercased().contains("PARTICULARLY DANGEROUS SITUATION")

        // Bulleted sections: "* Tornado Watch for portions of\n  Central Oklahoma\n ...", "* Effective ...", "* Primary threats include..."
        var areas: [String] = []
        var effective = ""
        var threats: [String] = []
        let bullets = text.components(separatedBy: "\n*").dropFirst()
        for b in bullets {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let head = lines.first?.lowercased() else { continue }
            let body = lines.dropFirst().prefix(while: { !$0.isEmpty }).map { String($0) }
            if head.contains("watch for portions of") || head.contains("watch for") {
                areas = body
            } else if head.hasPrefix("effective") {
                effective = WeatherAlert.unwrap(([lines[0]] + body).joined(separator: " "))
            } else if head.contains("primary threats") {
                // Threat lines start at column 2; continuation lines are indented further.
                var cur = ""
                for raw in b.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
                    let line = String(raw)
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    let indent = line.prefix(while: { $0 == " " }).count
                    if indent <= 2, !cur.isEmpty { threats.append(cur); cur = "" }
                    cur += (cur.isEmpty ? "" : " ") + line.trimmingCharacters(in: .whitespaces)
                }
                if !cur.isEmpty { threats.append(cur) }
            }
        }
        return SPCWatch(id: id, type: type, number: num, issued: issued, isPDS: pds, areas: areas,
                        effective: effective, threats: threats, rawText: text)
    }

    public func announcement(readThreats: Bool) -> String {
        var s: [String] = []
        if isPDS { s.append("Particularly dangerous situation") }
        var lead = "S P C issued \(type.lowercased()) \(number)"
        if !areas.isEmpty { lead += " for \(Spoken.list(areas.map { $0.lowercased() }))" }
        s.append(lead)
        if !effective.isEmpty { s.append(effective.replacingOccurrences(of: "Effective", with: "In effect")) }
        if readThreats && !threats.isEmpty { s.append("Primary threats: \(threats.joined(separator: "; ").lowercased())") }
        return Spoken.joinSentences(s)
    }
}

// MARK: - Convective outlook

public struct OutlookSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var day: Int
    public var issued: Date
    /// "...THERE IS A MARGINAL RISK OF SEVERE THUNDERSTORMS ACROSS ..." lines, cleaned.
    public var headlines: [String]
    public var maxCategory: OutlookCategory
    public var summary: String
    public var rawText: String
    /// Filled in from the GeoJSON layers when available.
    public var myCategory: OutlookCategory?
    public var myTornado: String?
    public var myWind: String?
    public var myHail: String?
    /// Day 3 (and beyond) only give a combined severe probability.
    public var mySevere: String?

    public var link: URL? { URL(string: "https://www.spc.noaa.gov/products/outlook/day\(day)otlk.html") }

    /// SPC's current outlook graphics for this day: (name, URL).
    public var imageLinks: [(String, URL)] {
        let base = "https://www.spc.noaa.gov/products/outlook/"
        var names: [(String, String)] = [("Categorical", "day\(day)otlk.png")]
        if day <= 2 {
            names += [("Tornado", "day\(day)probotlk_torn.png"), ("Wind", "day\(day)probotlk_wind.png"), ("Hail", "day\(day)probotlk_hail.png")]
        } else if day == 3 {
            names.append(("Severe probability", "day3prob.png"))
        }
        return names.compactMap { n in URL(string: base + n.1).map { (n.0, $0) } }
    }

    public static func parse(_ text: String, day: Int, id: String, issued: Date) -> OutlookSummary {
        let paras = text.components(separatedBy: "\n\n")
        let heads = paras.map { WeatherAlert.unwrap($0) }.filter { $0.hasPrefix("...THERE IS") || $0.hasPrefix("...NO SEVERE") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        var maxCat: OutlookCategory = .none
        let upper = heads.joined(separator: " ").uppercased()
        for (word, cat) in [("HIGH RISK", OutlookCategory.high), ("MODERATE RISK", .mdt), ("ENHANCED RISK", .enh), ("SLIGHT RISK", .slgt), ("MARGINAL RISK", .mrgl)] where upper.contains(word) {
            if cat > maxCat { maxCat = cat }
        }
        if maxCat == .none, text.uppercased().contains("GENERAL THUNDERSTORMS") || upper.contains("NO SEVERE") { maxCat = .tstm }
        return OutlookSummary(id: id, day: day, issued: issued, headlines: heads, maxCategory: maxCat,
                              summary: ProductText.field("...SUMMARY", in: text).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) } ?? "",
                              rawText: text)
    }

    public func announcement(sayMyRisk: Bool, readSummary: Bool) -> String {
        var s = ["S P C day \(day) convective outlook \(day == 1 ? "update" : "issued")"]
        if headlines.isEmpty {
            s.append("Highest risk is \(maxCategory.spoken)")
        } else {
            s += headlines.map { Spoken.sentenceCase($0) }
        }
        if sayMyRisk, let mine = myCategory {
            var me = "For your location, \(mine.spoken)"
            var probs: [String] = []
            if let t = myTornado { probs.append("\(t) tornado") }
            if let w = myWind { probs.append("\(w) wind") }
            if let h = myHail { probs.append("\(h) hail") }
            if let x = mySevere { probs.append("\(x) severe") }
            if !probs.isEmpty { me += ", with \(Spoken.list(probs)) probability" }
            s.append(me)
        }
        if readSummary && !summary.isEmpty { s.append(Spoken.normalizeForSpeech(summary)) }
        return Spoken.joinSentences(s)
    }
}

/// SPC outlook GeoJSON layer (categorical or probabilistic).
public struct OutlookLayer: Sendable {
    public struct Area: Sendable {
        public var label: String
        public var label2: String
        public var shape: GeoShape
    }
    public var areas: [Area]

    struct Collection: Decodable { var features: [Feature] }
    struct Feature: Decodable {
        var properties: Props
        var geometry: GeoJSONGeometry?
    }
    struct Props: Decodable {
        var LABEL: String?
        var LABEL2: String?
    }

    public static func parse(_ data: Data) throws -> OutlookLayer {
        let c = try JSONDecoder().decode(Collection.self, from: data)
        return OutlookLayer(areas: c.features.compactMap { f in
            guard let s = f.geometry?.shape else { return nil }
            return Area(label: f.properties.LABEL ?? "", label2: f.properties.LABEL2 ?? "", shape: s)
        })
    }

    /// Highest categorical risk containing the point.
    public func category(at p: GeoPoint) -> OutlookCategory {
        var best: OutlookCategory = .none
        for a in areas where Geo.contains(a.shape, p) {
            if let c = OutlookCategory(rawValue: a.label.uppercased()), c > best { best = c }
        }
        return best
    }

    /// Highest probability at the point, e.g. "5 percent" (ignores the "SIGN" hatched layer, noted separately).
    public func probability(at p: GeoPoint) -> String? {
        var best: Double = 0
        var sig = false
        for a in areas where Geo.contains(a.shape, p) {
            if a.label.uppercased() == "SIGN" { sig = true; continue }
            if let v = Double(a.label), v > best { best = v }
        }
        guard best > 0 else { return nil }
        return "\(Int((best * 100).rounded())) percent" + (sig ? " significant" : "")
    }

    public var maxCategory: OutlookCategory {
        areas.compactMap { OutlookCategory(rawValue: $0.label.uppercased()) }.max() ?? .none
    }
}

// MARK: - Area Forecast Discussion

public struct AreaForecastDiscussion: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var office: String
    public var issued: Date
    /// Section name ("KEY MESSAGES", "SHORT TERM"...) -> cleaned text, in product order.
    public var sections: [Section]
    public var rawText: String

    public struct Section: Codable, Hashable, Sendable {
        public var name: String
        public var text: String
    }

    public var link: URL? { URL(string: "https://forecast.weather.gov/product.php?site=\(office)&issuedby=\(office)&product=AFD&format=txt&version=1&glossary=0") }

    public static func parse(_ text: String, office: String, id: String, issued: Date) -> AreaForecastDiscussion {
        var sections: [Section] = []
        let lines = text.components(separatedBy: "\n")
        var name: String?
        var buf: [String] = []
        func flush() {
            guard let n = name else { return }
            let body = buf
                .filter { !$0.hasPrefix("Issued at") && !$0.hasPrefix("Updated at") && $0.trimmingCharacters(in: .whitespaces) != "Day" }
                .joined(separator: "\n")
            let cleaned = ProductText.paragraphs(body).joined(separator: "\n\n")
            if !cleaned.isEmpty { sections.append(Section(name: n, text: cleaned)) }
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("."), !t.hasPrefix("..."), let dots = t.range(of: "...") {
                flush()
                name = String(t[t.index(after: t.startIndex)..<dots.lowerBound]).uppercased()
                let after = String(t[dots.upperBound...])
                buf = after.isEmpty ? [] : [after]
            } else if t == "&&" || t == "$$" {
                flush()
                name = nil
                buf = []
            } else if name != nil {
                buf.append(line)
            }
        }
        flush()
        return AreaForecastDiscussion(id: id, office: office, issued: issued, sections: sections, rawText: text)
    }

    /// Text of the named sections (matching by prefix, e.g. "SHORT TERM" matches "SHORT TERM /THROUGH TONIGHT/").
    public func text(for names: [String]) -> [(String, String)] {
        var out: [(String, String)] = []
        for want in names {
            for s in sections where s.name.hasPrefix(want.uppercased()) && !out.contains(where: { $0.0 == s.name }) {
                out.append((s.name, s.text))
            }
        }
        return out
    }

    public func spoken(sections names: [String], officeName: String) -> String {
        var s = ["Area forecast discussion from the National Weather Service in \(officeName)."]
        let parts = text(for: names)
        if parts.isEmpty && !names.isEmpty { s.append("None of the selected sections are in this discussion") }
        for (n, t) in parts {
            s.append("\(n.capitalized).")
            s.append(Spoken.normalizeForSpeech(t.replacingOccurrences(of: "\n- ", with: ". ").replacingOccurrences(of: "- ", with: "")))
        }
        return s.joined(separator: " ")
    }
}
