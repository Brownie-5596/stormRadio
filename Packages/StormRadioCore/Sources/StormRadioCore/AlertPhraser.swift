import Foundation

/// Where an alert is relative to a point.
public struct AlertPosition: Hashable, Sendable {
    /// Miles to the alert (0 when inside).
    public var miles: Double
    /// Bearing from the point to the alert (nil when inside).
    public var bearing: Double?
    public var inside: Bool
}

public enum AlertGeo {
    /// Distance used for filtering: nearest edge, 0 when inside. `zoneMatch` marks zone alerts covering the user's county/zone.
    public static func rangeDistance(_ a: WeatherAlert, from p: GeoPoint, zoneMatch: Bool = false) -> Double? {
        if zoneMatch { return 0 }
        guard let g = a.geometry else { return nil }
        return Geo.distance(from: p, to: g)?.miles
    }

    public static func isInside(_ a: WeatherAlert, _ p: GeoPoint, zoneMatch: Bool = false) -> Bool {
        if zoneMatch { return true }
        guard let g = a.geometry else { return false }
        return Geo.contains(g, p)
    }

    /// Position used for speaking ("6 miles to the northeast").
    public static func position(of a: WeatherAlert, from p: GeoPoint, measure: DistanceMeasure, now: Date, zoneMatch: Bool = false) -> AlertPosition? {
        if isInside(a, p, zoneMatch: zoneMatch) { return AlertPosition(miles: 0, bearing: nil, inside: true) }
        guard let g = a.geometry else { return nil }
        switch measure {
        case .storm:
            if let m = a.motion {
                let pts = m.positions(at: now)
                if let nearest = pts.min(by: { Geo.distanceMiles(p, $0) < Geo.distanceMiles(p, $1) }) {
                    return AlertPosition(miles: Geo.distanceMiles(p, nearest), bearing: Geo.bearing(from: p, to: nearest), inside: false)
                }
            }
            fallthrough
        case .nearestEdge:
            guard let d = Geo.distance(from: p, to: g) else { return nil }
            return AlertPosition(miles: d.miles, bearing: Geo.bearing(from: p, to: d.nearest), inside: false)
        case .center:
            guard let c = Geo.centroid(g) else { return nil }
            return AlertPosition(miles: Geo.distanceMiles(p, c), bearing: Geo.bearing(from: p, to: c), inside: false)
        }
    }
}

/// Result of the in-path calculation.
public struct PathResult: Hashable, Sendable {
    public var inPath: Bool
    /// Minutes until the storm reaches the point (when in path).
    public var etaMinutes: Double?
    /// Miles from the projected track centerline.
    public var offTrackMiles: Double
    public var arrival: Date?

    public init(inPath: Bool, etaMinutes: Double?, offTrackMiles: Double, arrival: Date?) {
        self.inPath = inPath
        self.etaMinutes = etaMinutes
        self.offTrackMiles = offTrackMiles
        self.arrival = arrival
    }
}

public enum StormPath {
    /// Projects the storm forward and decides whether `point` is in its path.
    public static func evaluate(motion: StormMotion, point: GeoPoint, now: Date, halfWidthMiles: Double, maxMinutes: Double = 90) -> PathResult {
        let positions = motion.positions(at: now)
        let speed = motion.speedMPH
        guard speed >= 3, let origin = positions.first else {
            return PathResult(inPath: false, etaMinutes: nil, offTrackMiles: .infinity, arrival: nil)
        }
        let h = Geo.rad(motion.headingDegrees)
        let m = (x: sin(h), y: cos(h)) // unit motion vector, x east / y north
        let u = Geo.project(point, origin: origin)
        let pts = positions.map { Geo.project($0, origin: origin) }

        var best: (along: Double, off: Double)? = nil
        func consider(along: Double, off: Double) {
            guard along > 0 else { return }
            if best == nil || off < best!.off || (off <= halfWidthMiles && along < best!.along) { best = (along, off) }
        }

        if pts.count == 1 {
            let dx = u.x - pts[0].x, dy = u.y - pts[0].y
            consider(along: dx * m.x + dy * m.y, off: abs(dx * m.y - dy * m.x))
        } else {
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                // Solve u = a + s*(b-a) + d*m for s, d.
                let ex = b.x - a.x, ey = b.y - a.y
                let det = ex * m.y - m.x * ey
                if abs(det) > 1e-9 {
                    let rx = u.x - a.x, ry = u.y - a.y
                    let s = (rx * m.y - m.x * ry) / det
                    let d = (ex * ry - ey * rx) / det
                    let segLen = hypot(ex, ey)
                    let overshoot = s < 0 ? -s * segLen : (s > 1 ? (s - 1) * segLen : 0)
                    consider(along: d, off: overshoot)
                }
                for q in [a, b] {
                    let dx = u.x - q.x, dy = u.y - q.y
                    consider(along: dx * m.x + dy * m.y, off: abs(dx * m.y - dy * m.x))
                }
            }
        }
        guard let b = best else { return PathResult(inPath: false, etaMinutes: nil, offTrackMiles: .infinity, arrival: nil) }
        let eta = b.along / speed * 60
        let inPath = b.off <= halfWidthMiles && eta <= maxMinutes
        return PathResult(inPath: inPath, etaMinutes: eta, offTrackMiles: b.off, arrival: now.addingTimeInterval(eta * 60))
    }
}

/// How the alert is being introduced.
public enum AlertVerb: String, Sendable {
    case issued      // brand new
    case inEffect    // already active (startup summary, came into range, read on demand)
    case updated
}

public struct AlertContext {
    public var reference: GeoPoint?
    public var now: Date
    public var timeZone: TimeZone
    /// Zone-based alert that covers the user's county/zone.
    public var zoneMatch: Bool
    public var path: PathResult?
    public var verb: AlertVerb

    public init(reference: GeoPoint?, now: Date, timeZone: TimeZone = .current, zoneMatch: Bool = false, path: PathResult? = nil, verb: AlertVerb = .issued) {
        self.reference = reference
        self.now = now
        self.timeZone = timeZone
        self.zoneMatch = zoneMatch
        self.path = path
        self.verb = verb
    }
}

/// Builds spoken text for NWS alerts using the user's template.
public struct AlertPhraser {
    public var options: PhraseOptions
    public var template: MessageTemplate

    public init(options: PhraseOptions, template: MessageTemplate) {
        self.options = options
        self.template = template
    }

    // MARK: Fragments

    /// Lead-in sentence for emergencies / PDS ("Tornado emergency!").
    public func prefixSentence(_ a: WeatherAlert) -> String? {
        if a.isTornadoEmergency { return "Tornado emergency!" }
        if a.isFlashFloodEmergency { return "Flash flood emergency!" }
        if a.isPDS { return "Particularly dangerous situation." }
        return nil
    }

    /// Adjective tag placed before the event name ("considerable", "destructive").
    public func tagAdjective(_ a: WeatherAlert) -> String? {
        if a.event == "Tornado Warning" { return nil } // PDS/emergency handled by the prefix sentence
        if a.thunderstormDamage >= .considerable { return a.thunderstormDamage.spoken }
        if a.flashFloodDamage == .considerable { return "considerable" }
        return nil
    }

    public func eventName(_ a: WeatherAlert) -> String { a.event.lowercased() }

    public func position(_ a: WeatherAlert, _ ctx: AlertContext) -> AlertPosition? {
        guard let ref = ctx.reference else { return ctx.zoneMatch ? AlertPosition(miles: 0, bearing: nil, inside: true) : nil }
        return AlertGeo.position(of: a, from: ref, measure: options.distanceMeasure, now: ctx.now, zoneMatch: ctx.zoneMatch)
    }

    /// "6 miles to the northeast" / "for your location". `short` gives "6 miles northeast".
    public func distanceFragment(_ a: WeatherAlert, _ ctx: AlertContext, short: Bool = false) -> String? {
        guard let pos = position(a, ctx) else { return nil }
        if pos.inside { return short ? "over your location" : "for your location" }
        guard let b = pos.bearing else { return Spoken.distance(pos.miles) + " away" }
        let dir = Compass.name(for: b, style: options.compass)
        return short ? "\(Spoken.distance(pos.miles)) \(dir)" : "\(Spoken.distance(pos.miles)) to the \(dir)"
    }

    public func issuedAgoFragment(_ a: WeatherAlert, _ ctx: AlertContext) -> String? {
        guard options.issuedAgoMinMinutes >= 0 else { return nil }
        let ref: Date? = ctx.verb == .updated ? a.sent : (a.issuedTime ?? a.sent)
        guard let t = ref else { return nil }
        let mins = Spoken.minutesBetween(t, ctx.now)
        guard mins >= max(options.issuedAgoMinMinutes, 1), options.issuedAgoMaxMinutes <= 0 || mins <= options.issuedAgoMaxMinutes else { return nil }
        return "\(Spoken.duration(minutes: mins)) ago"
    }

    public func officeFragment(_ a: WeatherAlert) -> String? {
        guard !a.officeName.isEmpty else { return nil }
        return "by the National Weather Service in \(a.officeName)"
    }

    /// True if the SOURCE line reads like a short "who" phrase ("Trained weather spotters").
    func sourceIsShortNoun(_ s: String) -> Bool {
        let lower = s.lowercased()
        let verbs = ["report", "confirm", "indicat", "observ", "detect", "show"]
        return lower.split(separator: " ").count <= 4 && !verbs.contains(where: { lower.contains($0) })
    }

    public func threatsFragment(_ a: WeatherAlert) -> String? {
        let inlineSource = a.spokenSource.flatMap { sourceIsShortNoun($0) ? $0 : nil }

        func verb(_ b: ThreatBasis, plural: Bool) -> String {
            guard options.sayThreatBasis else { return plural ? "are possible" : "is possible" }
            switch b {
            case .radarIndicated: return plural ? "were indicated by radar" : "was indicated by radar"
            case .observed: return (plural ? "were observed" : "was observed") + (inlineSource.map { " by \($0)" } ?? "")
            case .radarConfirmed: return plural ? "were confirmed by radar" : "was confirmed by radar"
            case .possible: return plural ? "are possible" : "is possible"
            case .unknown: return plural ? "are expected" : "is expected"
            }
        }

        var parts: [String] = []
        switch a.tornadoDetection {
        case .radarIndicated: parts.append("a tornado was indicated by radar")
        case .observed: parts.append("a tornado was observed" + (inlineSource.map { " by \($0)" } ?? ""))
        case .radarConfirmed: parts.append("a tornado was confirmed by radar")
        case .possible: parts.append("a tornado is possible")
        case .unknown: break
        }

        // Wind and hail: group them when they share the same basis ("...wind gusts and 1 inch hail were indicated by radar").
        var items: [(text: String, basis: ThreatBasis, plural: Bool)] = []
        if let w = a.maxWindMPH { items.append(("\(Spoken.windAdjective(w)) wind gusts", a.windBasis, true)) }
        if let h = a.maxHailInches { items.append((Spoken.hail(h, style: options.hailStyle), a.hailBasis, false)) }
        if items.count == 2 && items[0].basis == items[1].basis {
            parts.append("\(items[0].text) and \(items[1].text) \(verb(items[0].basis, plural: true))")
        } else {
            for i in items { parts.append("\(i.text) \(verb(i.basis, plural: i.plural))") }
        }

        switch a.flashFloodDetection {
        case .radarIndicated: parts.append("flash flooding was indicated by radar")
        case .observed: parts.append("flash flooding was observed" + (inlineSource.map { " by \($0)" } ?? ""))
        default: break
        }
        if a.waterspoutDetection == .observed { parts.append("a waterspout was observed") }
        guard !parts.isEmpty else { return nil }
        return Spoken.list(parts)
    }

    public func hasThreatTags(_ a: WeatherAlert) -> Bool {
        a.tornadoDetection != .unknown || a.maxWindMPH != nil || a.maxHailInches != nil || a.flashFloodDetection != .unknown
    }

    public func sourceFragment(_ a: WeatherAlert, threatsSpoken: Bool) -> String? {
        guard let s = a.spokenSource else { return nil }
        let lower = s
        if threatsSpoken {
            if lower.hasPrefix("radar indicated") { return nil }           // already said "indicated by radar"
            let anyObserved = a.hailBasis == .observed || a.windBasis == .observed || a.tornadoDetection == .observed || a.flashFloodDetection == .observed
            if anyObserved && sourceIsShortNoun(s) { return nil }          // already said "observed by ..."
        }
        return "Source: \(Spoken.normalizeForSpeech(lower))"
    }

    public func hazardFragment(_ a: WeatherAlert) -> String? {
        guard !hasThreatTags(a), let h = a.hazardText else { return nil }
        return "Hazard: \(Spoken.normalizeForSpeech(h.lowercased()))"
    }

    func motionPhrase(_ m: StormMotion) -> String {
        let mph = Int((m.speedMPH / 5).rounded() * 5)
        if mph < 5 { return "nearly stationary" }
        return "moving \(Compass.name(for: m.headingDegrees, style: options.compass)) at \(mph) miles per hour"
    }

    public func stormFragment(_ a: WeatherAlert, _ ctx: AlertContext) -> String? {
        guard let m = a.motion else { return nil }
        guard let ref = ctx.reference else { return "The storm is \(motionPhrase(m))" }
        let pts = m.positions(at: ctx.now)
        guard let nearest = pts.min(by: { Geo.distanceMiles(ref, $0) < Geo.distanceMiles(ref, $1) }) else { return nil }
        let miles = Geo.distanceMiles(ref, nearest)
        let where_: String
        if miles < 1 { where_ = "over your location" } else {
            where_ = "\(Spoken.distance(miles)) to the \(Compass.name(for: Geo.bearing(from: ref, to: nearest), style: options.compass))"
        }
        return "The storm is \(where_), \(motionPhrase(m))"
    }

    public func motionFragment(_ a: WeatherAlert) -> String? {
        a.motion.map { Spoken.capitalizeFirst(motionPhrase($0)) }
    }

    public func expiresFragment(_ a: WeatherAlert, _ ctx: AlertContext) -> String? {
        guard let end = a.endTime else { return nil }
        let mins = Spoken.minutesBetween(ctx.now, end)
        if mins <= 0 { return "It has expired" }
        let clock = Spoken.clock(end, use24Hour: options.use24Hour, sayAMPM: options.sayAMPM, timeZone: ctx.timeZone)
        if mins > 180 { return options.expiresClock || options.expiresRelative ? "It is in effect until \(clock)" : nil }
        switch (options.expiresRelative, options.expiresClock) {
        case (true, true): return "It expires in \(Spoken.duration(minutes: mins)), at \(clock)"
        case (true, false): return "It expires in \(Spoken.duration(minutes: mins))"
        case (false, true): return "It expires at \(clock)"
        case (false, false): return nil
        }
    }

    public func citiesFragment(_ a: WeatherAlert) -> String? {
        let cities = a.locationsImpacted
        guard !cities.isEmpty, options.maxCities > 0 else { return nil }
        let shown = Array(cities.prefix(options.maxCities))
        let more = cities.count > shown.count ? ", among others" : ""
        return "Locations include \(Spoken.list(shown))\(more)"
    }

    public func countiesFragment(_ a: WeatherAlert) -> String? {
        let names = a.areaNames
        guard !names.isEmpty, options.maxCounties > 0 else { return nil }
        let shown = Array(names.prefix(options.maxCounties))
        let isCounty = !a.ugc.isEmpty && a.ugc.allSatisfy { $0.count >= 3 && Array($0)[2] == "C" }
        let more = names.count > shown.count ? " and \(names.count - shown.count) more" : ""
        return isCounty ? "Including \(Spoken.list(shown)) \(shown.count == 1 && more.isEmpty ? "county" : "counties")\(more)"
                        : "Including \(Spoken.list(shown))\(more)"
    }

    public func pathFragment(_ ctx: AlertContext) -> String? {
        guard let p = ctx.path, p.inPath, let eta = p.etaMinutes else { return nil }
        let mins = max(1, Int(eta.rounded()))
        var s = "You are in the path, arrival in about \(Spoken.duration(minutes: mins))"
        if let arr = p.arrival { s += ", around \(Spoken.clock(arr, use24Hour: options.use24Hour, sayAMPM: options.sayAMPM, timeZone: ctx.timeZone))" }
        return s
    }

    public func headlineFragment(_ a: WeatherAlert) -> String? {
        a.nwsHeadline.map { Spoken.sentenceCase($0) }
    }

    public func instructionsFragment(_ a: WeatherAlert) -> String? {
        guard let i = a.instruction, !i.isEmpty else { return nil }
        let flat = WeatherAlert.unwrap(i)
        if let dot = flat.firstIndex(where: { $0 == "." || $0 == "!" }) { return String(flat[...dot]) }
        return flat
    }

    // MARK: Compose

    static let headerKinds: Set<PhraseBlockKind> = [.tags, .event, .office, .issuedAgo, .distance]

    /// The full spoken announcement for an alert.
    public func compose(_ a: WeatherAlert, _ ctx: AlertContext) -> String {
        template.useCustomFormat ? composeCustom(a, ctx) : composeBlocks(a, ctx)
    }

    func verbPhrase(_ ctx: AlertContext) -> String {
        switch ctx.verb {
        case .issued: return "was issued"
        case .inEffect: return "is in effect"
        case .updated: return "was updated"
        }
    }

    func header(_ a: WeatherAlert, _ ctx: AlertContext, enabled: [PhraseBlockKind]) -> String {
        let on = Set(enabled)
        var words: [String] = []
        let adj = on.contains(.tags) ? tagAdjective(a) : nil
        let name = on.contains(.event) ? eventName(a) : "warning"
        let noun = [adj, name].compactMap { $0 }.joined(separator: " ")
        words.append("\(Spoken.article(for: noun)) \(noun)")
        words.append(verbPhrase(ctx))
        var trailingAgo: String? = nil
        for k in enabled {
            switch k {
            case .office: if let o = officeFragment(a) { words.append(o) }
            case .issuedAgo:
                if let ago = issuedAgoFragment(a, ctx) {
                    if ctx.verb == .inEffect { trailingAgo = "issued \(ago)" } else { words.append(ago) }
                }
            case .distance: if let d = distanceFragment(a, ctx) { words.append(d) }
            default: break
            }
        }
        var s = words.joined(separator: " ")
        if let t = trailingAgo { s += ", \(t)" }
        return s
    }

    func composeBlocks(_ a: WeatherAlert, _ ctx: AlertContext) -> String {
        let enabled = template.blocks.filter { $0.enabled }.map { $0.kind }
        var sentences: [String] = []
        var headerDone = false
        let threats = enabled.contains(.threats) ? threatsFragment(a) : nil

        if enabled.contains(.tags), let pre = prefixSentence(a) { sentences.append(pre) }
        for k in enabled {
            if Self.headerKinds.contains(k) {
                if !headerDone {
                    sentences.append(header(a, ctx, enabled: enabled.filter { Self.headerKinds.contains($0) }))
                    headerDone = true
                }
                continue
            }
            let frag: String?
            switch k {
            case .threats: frag = threats
            case .source: frag = sourceFragment(a, threatsSpoken: threats != nil)
            case .hazardText: frag = hazardFragment(a)
            case .storm: frag = stormFragment(a, ctx)
            case .motion: frag = enabled.contains(.storm) ? nil : motionFragment(a)
            case .expires: frag = expiresFragment(a, ctx)
            case .cities: frag = citiesFragment(a)
            case .counties: frag = countiesFragment(a)
            case .path: frag = pathFragment(ctx)
            case .headline: frag = headlineFragment(a)
            case .instructions: frag = instructionsFragment(a)
            default: frag = nil
            }
            if let f = frag { sentences.append(f) }
        }
        return Spoken.joinSentences(sentences)
    }

    /// Values available to the custom text format.
    public func placeholderValues(_ a: WeatherAlert, _ ctx: AlertContext) -> [String: String] {
        let threats = threatsFragment(a)
        let adj = tagAdjective(a)
        let noun = [adj, eventName(a)].compactMap { $0 }.joined(separator: " ")
        var v: [String: String] = [
            "a": Spoken.article(for: noun),
            "tags": [prefixSentence(a), adj].compactMap { $0 }.joined(separator: " "),
            "event": eventName(a),
            "verb": verbPhrase(ctx),
            "office": officeFragment(a) ?? "",
            "issuedAgo": issuedAgoFragment(a, ctx) ?? "",
            "distance": distanceFragment(a, ctx) ?? "",
            "threats": threats ?? "",
            "source": sourceFragment(a, threatsSpoken: threats != nil) ?? "",
            "hazardText": hazardFragment(a) ?? "",
            "storm": stormFragment(a, ctx) ?? "",
            "motion": motionFragment(a) ?? "",
            "expires": expiresFragment(a, ctx) ?? "",
            "cities": citiesFragment(a) ?? "",
            "counties": countiesFragment(a) ?? "",
            "path": pathFragment(ctx) ?? "",
            "headline": headlineFragment(a) ?? "",
            "instructions": instructionsFragment(a) ?? "",
        ]
        if let end = a.endTime {
            v["expiresAt"] = Spoken.clock(end, use24Hour: options.use24Hour, sayAMPM: options.sayAMPM, timeZone: ctx.timeZone)
            v["expiresIn"] = Spoken.duration(minutes: max(0, Spoken.minutesBetween(ctx.now, end)))
        }
        return v
    }

    func composeCustom(_ a: WeatherAlert, _ ctx: AlertContext) -> String {
        var s = template.customFormat
        for (k, v) in placeholderValues(a, ctx) {
            s = s.replacingOccurrences(of: "{\(k)}", with: v)
        }
        // Remove unknown placeholders.
        while let open = s.range(of: "{"), let close = s.range(of: "}", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return Spoken.tidy(s)
    }

    /// Short title for the feed/notifications: "Severe Thunderstorm Warning · 6 mi NE".
    public func title(_ a: WeatherAlert, _ ctx: AlertContext) -> String {
        var t = a.event
        if a.isTornadoEmergency { t = "TORNADO EMERGENCY" } else if a.isFlashFloodEmergency { t = "FLASH FLOOD EMERGENCY" }
        else if a.isPDS { t = "PDS " + t } else if let adj = tagAdjective(a) { t = adj.capitalized + " " + t }
        if let pos = position(a, ctx) {
            if pos.inside { t += " · your location" }
            else if let b = pos.bearing { t += " · \(Int(pos.miles.rounded())) mi \(Compass.abbreviation(for: b))" }
        }
        return t
    }
}
