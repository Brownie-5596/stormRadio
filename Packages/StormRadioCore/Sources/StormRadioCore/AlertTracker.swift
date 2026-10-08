import Foundation

/// A meaningful difference between two versions of the same alert.
public enum AlertChange: Hashable, Sendable {
    case extended(to: Date)
    case shortened(to: Date)
    case hail(from: Double?, to: Double?, basis: ThreatBasis)
    case hailBasis(to: ThreatBasis)
    case wind(from: Int?, to: Int?, basis: ThreatBasis)
    case windBasis(to: ThreatBasis)
    case tornado(from: ThreatBasis, to: ThreatBasis)
    case damage(from: DamageTag, to: DamageTag)
    case becamePDS
    case becameEmergency
    case areaReduced(percent: Int)
    case areaExpanded(percent: Int)
    case areasAdded([String])
    case areasRemoved([String])

    /// Changes that make the situation more dangerous.
    public var isEscalation: Bool {
        switch self {
        case .hail(let f, let t, _): return (t ?? 0) > (f ?? 0)
        case .hailBasis(let b), .windBasis(let b): return b == .observed
        case .wind(let f, let t, _): return (t ?? 0) > (f ?? 0)
        case .tornado(let f, let t): return Self.tornadoRank(t) > Self.tornadoRank(f)
        case .damage(let f, let t): return t > f
        case .becamePDS, .becameEmergency: return true
        default: return false
        }
    }

    public var isThreatChange: Bool {
        switch self {
        case .hail, .hailBasis, .wind, .windBasis, .tornado, .damage, .becamePDS, .becameEmergency: return true
        default: return false
        }
    }

    static func tornadoRank(_ b: ThreatBasis) -> Int {
        switch b {
        case .unknown: return 0
        case .possible: return 1
        case .radarIndicated: return 2
        case .observed, .radarConfirmed: return 3
        }
    }
}

/// Everything we know about one event (all messages sharing a VTEC event key).
public struct TrackedEvent: Identifiable, Sendable {
    public var key: String
    public var id: String { key }
    /// Newest message that is not a cancellation/expiration.
    public var latest: WeatherAlert
    /// Active (non-ending) messages for this event from the latest poll; zone-based events can have several segments.
    public var activeMessages: [WeatherAlert]
    public var firstSeen: Date
    /// True when first seen as a NEW issuance (as opposed to already in progress).
    public var seenAsNew: Bool
    public var ended: Bool = false
    public var endedAt: Date?
    public var missingPolls: Int = 0

    // State maintained by the monitor
    public var announced: Bool = false
    public var inRange: Bool = false
    public var userInside: Bool = false
    public var pathThresholdsFired: Set<Int> = []
    public var lastPathETA: Double?

    /// Union of UGC codes across active segments.
    public var ugc: Set<String> { Set(activeMessages.flatMap { $0.ugc }).union(latest.ugc) }

    /// Merged view used for distance checks: polygon events use the newest polygon, zone events union all segments.
    public var current: WeatherAlert {
        var a = latest
        if !a.geometryFromZones, a.geometry != nil { return a }
        let shapes = activeMessages.compactMap { $0.geometry }.flatMap { $0.polygons }
        if !shapes.isEmpty { a.geometry = GeoShape(polygons: shapes) }
        a.ugc = Array(ugc).sorted()
        if activeMessages.count > 1 {
            var names: [String] = []
            for n in activeMessages.flatMap({ $0.areaNames }) where !names.contains(n) { names.append(n) }
            a.areaDesc = names.joined(separator: "; ")
        }
        return a
    }
}

/// Lifecycle events produced by comparing polls.
public enum AlertLifecycle: Sendable {
    /// Already active at the first poll.
    case initial(String)
    /// Newly issued (or first seen after startup).
    case issued(String)
    case updated(String, previous: WeatherAlert, changes: [AlertChange])
    case partiallyCancelled(String, cancel: WeatherAlert, previous: WeatherAlert, changes: [AlertChange])
    case cancelled(String, message: WeatherAlert)
    /// EXP message received or the event vanished at/after its end time.
    case expired(String, message: WeatherAlert?)
    /// Vanished before its end time with no cancellation message.
    case ended(String)
    /// The event was replaced by another (VTEC UPG), e.g. watch -> warning.
    case upgraded(String, toEvent: String)

    public var key: String {
        switch self {
        case .initial(let k), .issued(let k), .ended(let k): return k
        case .updated(let k, _, _), .partiallyCancelled(let k, _, _, _), .cancelled(let k, _), .expired(let k, _), .upgraded(let k, _): return k
        }
    }
}

/// Keeps the set of active events and turns successive polls into lifecycle events.
public final class AlertTracker {
    public private(set) var events: [String: TrackedEvent] = [:]
    private var seen: [String: Date] = [:]
    public private(set) var initialized = false
    public var areaChangeThresholdPercent: Int = 15

    public init() {}

    public func reset() {
        events = [:]
        seen = [:]
        initialized = false
    }

    public func event(_ key: String) -> TrackedEvent? { events[key] }

    public func update(_ key: String, _ body: (inout TrackedEvent) -> Void) {
        guard var e = events[key] else { return }
        body(&e)
        events[key] = e
    }

    public var activeEvents: [TrackedEvent] { events.values.filter { !$0.ended } }

    static func eventKey(for v: VTEC) -> String {
        // SPC watches are numbered nationally; WFOs each issue their own county segments under the same number.
        if v.significance == "A", v.phenomena == "TO" || v.phenomena == "SV" {
            return "SPC.\(v.phenomena).A.\(String(format: "%04d", v.eventNumber))"
        }
        return v.eventKey
    }

    static func key(_ a: WeatherAlert) -> String {
        a.primaryVTEC.map(eventKey(for:)) ?? "ID:\(a.id)"
    }

    /// Feed the full list of currently active alerts. Returns what changed.
    public func ingest(_ alerts: [WeatherAlert], now: Date) -> [AlertLifecycle] {
        var out: [AlertLifecycle] = []
        let actual = alerts.filter { $0.status.lowercased() == "actual" }
        var byKey: [String: [WeatherAlert]] = [:]
        for a in actual { byKey[Self.key(a), default: []].append(a) }

        // Upgrades: a message carrying an UPG VTEC ends that older event.
        for a in actual where seen[a.id] == nil {
            for v in a.vtec where v.action == .upg {
                let k = Self.eventKey(for: v)
                if var e = events[k], !e.ended {
                    e.ended = true
                    e.endedAt = now
                    events[k] = e
                    out.append(.upgraded(k, toEvent: a.event))
                }
            }
        }

        for (key, msgs) in byKey {
            let fresh = msgs.filter { seen[$0.id] == nil }.sorted { ($0.sent ?? .distantPast) < ($1.sent ?? .distantPast) }
            let ongoing = msgs.filter { !($0.primaryVTEC?.action.isEnding ?? false) && $0.messageType != "Cancel" }
            for m in fresh { seen[m.id] = now }

            if var e = events[key] {
                let before = e.current
                e.missingPolls = 0
                if !ongoing.isEmpty { e.activeMessages = ongoing }
                guard !fresh.isEmpty, !e.ended else { events[key] = e; continue }
                let cancels = fresh.filter { $0.primaryVTEC?.action == .can || ($0.messageType == "Cancel" && $0.primaryVTEC?.action != .exp) }
                let exps = fresh.filter { $0.primaryVTEC?.action == .exp }
                let others = fresh.filter { m in !cancels.contains(where: { $0.id == m.id }) && !exps.contains(where: { $0.id == m.id }) }
                let previous = before
                if let newest = others.last {
                    e.latest = newest
                    let changes = Self.diff(before, e.current, areaThreshold: areaChangeThresholdPercent)
                    if let c = cancels.last {
                        out.append(.partiallyCancelled(key, cancel: c, previous: previous, changes: changes))
                    } else {
                        out.append(.updated(key, previous: previous, changes: changes))
                    }
                } else if let c = cancels.last {
                    if ongoing.isEmpty {
                        e.ended = true
                        e.endedAt = now
                        out.append(.cancelled(key, message: c))
                    } else {
                        // Some segments cancelled, others still active (zone-based products).
                        let changes = Self.diff(before, e.current, areaThreshold: areaChangeThresholdPercent)
                        out.append(.partiallyCancelled(key, cancel: c, previous: previous, changes: changes))
                    }
                } else if let x = exps.last {
                    if ongoing.isEmpty {
                        e.ended = true
                        e.endedAt = now
                        out.append(.expired(key, message: x))
                    }
                }
                events[key] = e
            } else {
                // Unknown event. Ignore if all we have is its ending.
                guard let newest = ongoing.max(by: { ($0.sent ?? .distantPast) < ($1.sent ?? .distantPast) }) else { continue }
                if let end = newest.endTime, end < now { continue }
                let isNew = fresh.contains { $0.primaryVTEC?.action == .new } || newest.primaryVTEC == nil && newest.messageType == "Alert"
                let e = TrackedEvent(key: key, latest: newest, activeMessages: ongoing, firstSeen: now, seenAsNew: initialized && isNew)
                events[key] = e
                out.append(initialized ? .issued(key) : .initial(key))
            }
        }

        // Events that disappeared from the feed.
        for (key, var e) in events where !e.ended && byKey[key] == nil {
            e.missingPolls += 1
            if e.missingPolls >= 2 {
                e.ended = true
                e.endedAt = now
                if let end = e.latest.endTime, now.addingTimeInterval(120) >= end {
                    out.append(.expired(key, message: nil))
                } else {
                    out.append(.ended(key))
                }
            }
            events[key] = e
        }

        // Forget long-ended events and old message ids.
        let cutoff = now.addingTimeInterval(-3 * 3600)
        events = events.filter { !$0.value.ended || ($0.value.endedAt ?? now) > now.addingTimeInterval(-1800) }
        seen = seen.filter { $0.value > cutoff }

        initialized = true
        return out
    }

    /// Compares two versions of an alert.
    public static func diff(_ old: WeatherAlert, _ new: WeatherAlert, areaThreshold: Int = 15) -> [AlertChange] {
        var c: [AlertChange] = []
        if let oe = old.endTime, let ne = new.endTime {
            if ne.timeIntervalSince(oe) > 90 { c.append(.extended(to: ne)) }
            else if oe.timeIntervalSince(ne) > 90 { c.append(.shortened(to: ne)) }
        }
        if old.maxHailInches != new.maxHailInches, new.maxHailInches != nil || old.maxHailInches != nil {
            c.append(.hail(from: old.maxHailInches, to: new.maxHailInches, basis: new.hailBasis))
        } else if new.maxHailInches != nil, old.hailBasis != new.hailBasis, new.hailBasis == .observed {
            c.append(.hailBasis(to: new.hailBasis))
        }
        if old.maxWindMPH != new.maxWindMPH, new.maxWindMPH != nil || old.maxWindMPH != nil {
            c.append(.wind(from: old.maxWindMPH, to: new.maxWindMPH, basis: new.windBasis))
        } else if new.maxWindMPH != nil, old.windBasis != new.windBasis, new.windBasis == .observed {
            c.append(.windBasis(to: new.windBasis))
        }
        if old.tornadoDetection != new.tornadoDetection {
            c.append(.tornado(from: old.tornadoDetection, to: new.tornadoDetection))
        }
        let od = max(old.thunderstormDamage, old.tornadoDamage, old.flashFloodDamage)
        let nd = max(new.thunderstormDamage, new.tornadoDamage, new.flashFloodDamage)
        if od != nd { c.append(.damage(from: od, to: nd)) }
        if new.isEmergency && !old.isEmergency { c.append(.becameEmergency) }
        else if new.isPDS && !old.isPDS { c.append(.becamePDS) }

        if let og = old.geometry, let ng = new.geometry, !old.geometryFromZones, !new.geometryFromZones {
            let oa = Geo.areaSquareMiles(og), na = Geo.areaSquareMiles(ng)
            if oa > 0 {
                let pct = Int(((na - oa) / oa * 100).rounded())
                if pct <= -areaThreshold { c.append(.areaReduced(percent: -pct)) }
                else if pct >= areaThreshold { c.append(.areaExpanded(percent: pct)) }
            }
        } else {
            let oldNames = Set(old.areaNames), newNames = Set(new.areaNames)
            let added = new.areaNames.filter { !oldNames.contains($0) }
            let removed = old.areaNames.filter { !newNames.contains($0) }
            if !added.isEmpty && !oldNames.isEmpty { c.append(.areasAdded(added)) }
            if !removed.isEmpty && !newNames.isEmpty { c.append(.areasRemoved(removed)) }
        }
        return c
    }
}
