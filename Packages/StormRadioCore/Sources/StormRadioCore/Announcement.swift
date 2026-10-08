import Foundation

public enum AnnouncementCategory: String, Codable, CaseIterable, Sendable {
    case warning      // new NWS alert
    case update       // change / cancellation / expiration of an alert
    case location     // you entered / left a warning
    case path         // storm heading your way
    case report       // storm report
    case md           // SPC mesoscale discussion
    case watch        // SPC watch issuance
    case outlook      // SPC convective outlook
    case afd          // area forecast discussion
    case summary      // on-demand / startup summaries
    case system       // app status messages

    public var label: String {
        switch self {
        case .warning: return "Alerts"
        case .update: return "Updates"
        case .location: return "Entered / left"
        case .path: return "In path"
        case .report: return "Reports"
        case .md: return "Meso discussions"
        case .watch: return "SPC watches"
        case .outlook: return "Outlooks"
        case .afd: return "AFDs"
        case .summary: return "Summaries"
        case .system: return "System"
        }
    }
}

/// One thing the radio wants to tell you.
public struct Announcement: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var date: Date
    public var category: AnnouncementCategory
    public var title: String
    public var spokenText: String
    /// Longer text for the feed detail page (product text, report remarks...).
    public var detailText: String
    public var mode: AnnounceMode
    public var tone: ToneID
    public var priority: Int
    public var canInterrupt: Bool
    public var notify: Bool
    public var link: URL?
    public var eventKey: String?
    /// The NWS event / report type, used for icons and colors.
    public var kind: String?
    public var point: GeoPoint?

    public init(id: String = UUID().uuidString, date: Date, category: AnnouncementCategory, title: String, spokenText: String,
                detailText: String = "", mode: AnnounceMode = .speak, tone: ToneID = .none, priority: Int = 5, canInterrupt: Bool = false,
                notify: Bool = true, link: URL? = nil, eventKey: String? = nil, kind: String? = nil, point: GeoPoint? = nil) {
        self.id = id
        self.date = date
        self.category = category
        self.title = title
        self.spokenText = spokenText
        self.detailText = detailText
        self.mode = mode
        self.tone = tone
        self.priority = priority
        self.canInterrupt = canInterrupt
        self.notify = notify
        self.link = link
        self.eventKey = eventKey
        self.kind = kind
        self.point = point
    }
}

// MARK: - Update / lifecycle wording

public extension AlertPhraser {
    /// "the severe thunderstorm warning 6 miles northeast"
    func reference(_ a: WeatherAlert, _ ctx: AlertContext) -> String {
        let name = eventName(a)
        if let d = distanceFragment(a, ctx, short: true) { return "the \(name) \(d)" }
        if let first = a.areaNames.first { return "the \(name) for \(first)" }
        return "the \(name)"
    }

    func clock(_ d: Date, _ ctx: AlertContext) -> String {
        Spoken.clock(d, use24Hour: options.use24Hour, sayAMPM: options.sayAMPM, timeZone: ctx.timeZone)
    }

    func basisWord(_ b: ThreatBasis, source: String?) -> String {
        switch b {
        case .observed:
            if let s = source, sourceIsShortNoun(s) { return "observed by \(s)" }
            return "observed"
        case .radarIndicated: return "indicated by radar"
        case .radarConfirmed: return "confirmed by radar"
        case .possible: return "possible"
        case .unknown: return ""
        }
    }

    func changeSentence(_ c: AlertChange, _ a: WeatherAlert, _ ctx: AlertContext) -> String? {
        let src = a.spokenSource
        switch c {
        case .extended(let to): return "It has been extended until \(clock(to, ctx))"
        case .shortened(let to): return "It now ends at \(clock(to, ctx))"
        case .hail(let from, let to, let basis):
            guard let t = to else { return "Hail is no longer mentioned" }
            let size = Spoken.hail(t, style: options.hailStyle).replacingOccurrences(of: " hail", with: "")
            let b = basisWord(basis, source: src)
            guard let f = from else { return "It now includes \(size) hail\(b.isEmpty ? "" : ", \(b)")" }
            return "Hail \(t > f ? "increased" : "decreased") to \(size)\(b.isEmpty ? "" : ", \(b)")"
        case .hailBasis(let b): return "Hail has now been \(basisWord(b, source: src))"
        case .wind(let from, let to, let basis):
            guard let t = to else { return "Damaging wind is no longer mentioned" }
            let b = basisWord(basis, source: src)
            guard let f = from else { return "It now includes \(t) mile per hour wind gusts\(b.isEmpty ? "" : ", \(b)")" }
            return "Wind gusts \(t > f ? "increased" : "decreased") to \(t) miles per hour\(b.isEmpty ? "" : ", \(b)")"
        case .windBasis(let b): return "Damaging winds have now been \(basisWord(b, source: src))"
        case .tornado(let from, let to):
            switch to {
            case .observed: return "A tornado has now been observed" + (src.map { sourceIsShortNoun($0) ? " by \($0)" : ". Source: \($0)" } ?? "")
            case .radarConfirmed: return "A tornado has now been confirmed by radar"
            case .radarIndicated:
                return AlertChange.tornadoRank(from) > AlertChange.tornadoRank(to) ? "The tornado is now radar indicated rather than observed" : "A tornado is now indicated by radar"
            case .possible:
                return AlertChange.tornadoRank(from) > AlertChange.tornadoRank(to) ? "The tornado threat was lowered to possible" : "A tornado is now possible"
            case .unknown: return "A tornado is no longer mentioned"
            }
        case .damage(let from, let to):
            if to == .none || to == .base { return "The \(from.spoken) damage tag was removed" }
            return to > from ? "The damage threat was raised to \(to.spoken)" : "The damage threat was lowered to \(to.spoken)"
        case .becamePDS: return "It is now a particularly dangerous situation"
        case .becameEmergency: return a.isTornadoEmergency ? "It is now a tornado emergency" : "It is now an emergency"
        case .areaReduced(let pct):
            return "Its area was reduced by about \(pct) percent"
        case .areaExpanded: return "Its area was expanded"
        case .areasAdded(let names): return "It now also includes \(Spoken.list(Array(names.prefix(options.maxCounties))))"
        case .areasRemoved(let names): return "It no longer includes \(Spoken.list(Array(names.prefix(options.maxCounties))))"
        }
    }

    func shortExpires(_ a: WeatherAlert, _ ctx: AlertContext) -> String? {
        guard let end = a.endTime else { return nil }
        let mins = Spoken.minutesBetween(ctx.now, end)
        guard mins > 0 else { return nil }
        if mins > 180 { return "It remains in effect until \(clock(end, ctx))" }
        return "It expires in \(Spoken.duration(minutes: mins)), at \(clock(end, ctx))"
    }

    func updateText(_ a: WeatherAlert, changes: [AlertChange], _ ctx: AlertContext) -> String {
        var s = ["Update on \(reference(a, ctx))"]
        s += changes.compactMap { changeSentence($0, a, ctx) }
        if !changes.contains(where: { if case .extended = $0 { return true }; return false }), let e = shortExpires(a, ctx) { s.append(e) }
        return Spoken.joinSentences(s)
    }

    func firstSentence(_ text: String) -> String? {
        let paras = text.components(separatedBy: "\n\n").map(WeatherAlert.unwrap).filter { !$0.isEmpty }
        guard let p = paras.first(where: { !$0.hasPrefix("*") && $0.count > 20 }) else { return nil }
        if let dot = p.firstIndex(of: ".") { return String(p[...dot]) }
        return p
    }

    func cancelText(_ a: WeatherAlert, cancel: WeatherAlert, includeReason: Bool, _ ctx: AlertContext) -> String {
        var s = ["\(Spoken.capitalizeFirst(reference(a, ctx))) has been cancelled"]
        if includeReason, let r = firstSentence(cancel.description) { s.append(r) }
        return Spoken.joinSentences(s)
    }

    func partialCancelText(_ a: WeatherAlert, cancel: WeatherAlert, changes: [AlertChange], _ ctx: AlertContext) -> String {
        var s: [String] = []
        if let h = cancel.nwsHeadline {
            s.append("Part of \(reference(a, ctx)) was cancelled. \(Spoken.sentenceCase(h))")
        } else {
            s.append("Part of \(reference(a, ctx)) was cancelled")
        }
        s += changes.filter { if case .areaReduced = $0 { return false }; return true }.compactMap { changeSentence($0, a, ctx) }
        if let e = shortExpires(a, ctx) { s.append(e.replacingOccurrences(of: "It expires", with: "The rest expires")) }
        return Spoken.joinSentences(s)
    }

    func expiredText(_ a: WeatherAlert, message: WeatherAlert?, _ ctx: AlertContext) -> String {
        if let end = a.endTime, end.timeIntervalSince(ctx.now) > 60 {
            return Spoken.joinSentences(["\(Spoken.capitalizeFirst(reference(a, ctx))) will be allowed to expire at \(clock(end, ctx))"])
        }
        return Spoken.joinSentences(["\(Spoken.capitalizeFirst(reference(a, ctx))) has expired"])
    }

    func endedText(_ a: WeatherAlert, _ ctx: AlertContext) -> String {
        Spoken.joinSentences(["\(Spoken.capitalizeFirst(reference(a, ctx))) is no longer in effect"])
    }

    func enteredText(_ a: WeatherAlert, details: Bool, _ ctx: AlertContext) -> String {
        let adj = tagAdjective(a)
        let noun = [adj, eventName(a)].compactMap { $0 }.joined(separator: " ")
        var s: [String] = []
        if let pre = prefixSentence(a) { s.append(pre) }
        s.append("You have entered \(Spoken.article(for: noun)) \(noun)")
        if details {
            if let t = threatsFragment(a) { s.append(t) } else if let h = hazardFragment(a) { s.append(h) }
            if let e = expiresFragment(a, ctx) { s.append(e) }
        }
        return Spoken.joinSentences(s)
    }

    func leftText(_ a: WeatherAlert, _ ctx: AlertContext) -> String {
        Spoken.joinSentences(["You have left the \(eventName(a))"])
    }

    func pathText(_ a: WeatherAlert, path: PathResult, _ ctx: AlertContext) -> String {
        var desc: String
        switch a.event {
        case "Tornado Warning": desc = "the tornado warned storm"
        case "Severe Thunderstorm Warning":
            var threats: [String] = []
            if let h = a.maxHailInches { threats.append(Spoken.hail(h, style: options.hailStyle)) }
            if let w = a.maxWindMPH { threats.append("\(w) mile per hour winds") }
            desc = "the severe thunderstorm" + (threats.isEmpty ? "" : " with \(Spoken.list(threats))")
        default: desc = "the storm in the \(eventName(a))"
        }
        if let adj = tagAdjective(a) { desc = desc.replacingOccurrences(of: "the ", with: "the \(adj) ", options: .anchored) }
        var s: [String] = []
        if let pre = prefixSentence(a) { s.append(pre) }
        s.append("You are in the path of \(desc)")
        if let eta = path.etaMinutes {
            var arr = "Arrival in about \(Spoken.duration(minutes: max(1, Int(eta.rounded()))))"
            if let t = path.arrival { arr += ", around \(clock(t, ctx))" }
            s.append(arr)
        }
        if let st = stormFragment(a, ctx) { s.append(st) }
        return Spoken.joinSentences(s)
    }
}
