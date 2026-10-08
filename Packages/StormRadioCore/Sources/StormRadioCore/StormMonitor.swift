import Foundation

public struct SourceStatus: Hashable, Sendable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var itemCount: Int = 0

    public var ok: Bool { lastError == nil && lastSuccess != nil }
}

/// One active alert as shown in the app.
public struct ActiveAlertInfo: Identifiable, Sendable {
    public var id: String
    public var alert: WeatherAlert
    public var title: String
    public var distanceMiles: Double?
    public var bearing: Double?
    public var inside: Bool
    public var inRange: Bool
    public var risk: Int
    public var path: PathResult?
    public var priority: Int
}

/// The brain of the radio: polls the data sources, tracks what changed and decides what to announce.
///
/// An actor, so polling, location updates and on-demand reads can safely overlap.
public actor StormMonitor {
    public private(set) var settings: AppSettings
    public var profile: Profile { settings.activeProfile }
    public let client: WeatherClient
    public let tracker = AlertTracker()
    public private(set) var timeZone: TimeZone = .current

    public private(set) var gpsPoint: GeoPoint?
    public private(set) var pointInfo: PointInfo?
    public private(set) var reports: [String: StormReport] = [:]
    public private(set) var mds: [MesoscaleDiscussion] = []
    public private(set) var watches: [SPCWatch] = []
    public private(set) var outlooks: [Int: OutlookSummary] = [:]
    public private(set) var afds: [String: AreaForecastDiscussion] = [:]
    public private(set) var status: [String: SourceStatus] = [:]
    /// Zone/county outlines keyed by API URL. The app can persist this between launches.
    public private(set) var zoneCache: [String: GeoShape] = [:]

    var outlookLayers: [Int: [String: OutlookLayer]] = [:]
    var seenReports: Set<String> = []
    var reportsInitialized = false
    var announcedReports: [StormReport] = []
    var seenProducts: Set<String> = []
    var initializedFeeds: Set<String> = []
    var needsStartupSummary = true
    var pointInfoTask: Date?

    public init(settings: AppSettings, client: WeatherClient = WeatherClient()) {
        self.settings = settings
        self.client = client
        client.contactInfo = settings.general.contactInfo
        client.mpingAPIKey = settings.general.mpingAPIKey
        tracker.areaChangeThresholdPercent = max(5, settings.activeProfile.updates.areaReducedMinPercent)
    }

    // MARK: Settings & location

    public func setTimeZone(_ tz: TimeZone) { timeZone = tz }

    public func setZoneCache(_ cache: [String: GeoShape]) { zoneCache.merge(cache) { a, _ in a } }

    public var activeEventCount: Int { tracker.activeEvents.count }

    /// Speak a startup summary on the next alert poll (e.g. when monitoring is switched on).
    public func requestStartupSummary() { needsStartupSummary = true }

    /// Apply new settings. Alert state is re-baselined quietly so a settings change doesn't cause a burst of speech.
    public func apply(settings new: AppSettings) {
        let profileChanged = new.activeProfileID != settings.activeProfileID
        let alertSettingsChanged = new.activeProfile.alertRules != profile.alertRules
            || new.activeProfile.location != profile.location
            || new.activeProfile.otherAlertsRule != profile.otherAlertsRule
        settings = new
        client.contactInfo = new.general.contactInfo
        client.mpingAPIKey = new.general.mpingAPIKey
        tracker.areaChangeThresholdPercent = max(5, profile.updates.areaReducedMinPercent)
        if profileChanged || alertSettingsChanged {
            tracker.reset()
            if profileChanged { needsStartupSummary = true }
        }
    }

    /// The point distances are measured from: GPS or the fixed point (falls back to the other, then the polygon center).
    public var referencePoint: GeoPoint? {
        let loc = profile.location
        let p: GeoPoint?
        switch loc.mode {
        case .fixed: p = loc.fixedPoint ?? gpsPoint
        case .gps: p = gpsPoint ?? loc.fixedPoint
        }
        if p == nil, loc.areaMode == .polygon, loc.polygon.count >= 3 { return Geo.centroid(GeoShape(ring: loc.polygon)) }
        return p
    }

    var usingGPS: Bool { profile.location.mode == .gps && gpsPoint != nil }

    var areaPolygon: GeoShape? {
        let loc = profile.location
        guard loc.areaMode == .polygon, loc.polygon.count >= 3 else { return nil }
        return GeoShape(ring: loc.polygon)
    }

    /// Call when the phone's location changes. Returns entered/left/path announcements.
    public func updateLocation(_ p: GeoPoint?, now: Date) -> [Announcement] {
        gpsPoint = p
        guard tracker.initialized else { return [] }
        return evaluateLocation(now: now)
    }

    func refreshPointInfoIfNeeded() async {
        guard let ref = referencePoint else { return }
        if let info = pointInfo, Geo.distanceMiles(info.point, ref) < 3 { return }
        if let last = pointInfoTask, Date().timeIntervalSince(last) < 20 { return }
        pointInfoTask = Date()
        do {
            pointInfo = try await client.pointInfo(ref)
            markOK("NWS location", count: 1)
        } catch {
            markError("NWS location", error)
        }
    }

    func alertStates() -> [String]? {
        guard settings.general.limitToNearbyStates, let st = pointInfo?.state, StateNeighbors.map[st] != nil else { return nil }
        return StateNeighbors.withNeighbors([st])
    }

    func markOK(_ source: String, count: Int) {
        var s = status[source] ?? SourceStatus()
        s.lastAttempt = Date()
        s.lastSuccess = Date()
        s.lastError = nil
        s.itemCount = count
        status[source] = s
    }

    func markError(_ source: String, _ error: Error) {
        var s = status[source] ?? SourceStatus()
        s.lastAttempt = Date()
        s.lastError = error.localizedDescription
        status[source] = s
    }

    // MARK: Range logic

    func zoneMatch(_ a: WeatherAlert) -> Bool {
        guard let info = pointInfo, let ref = referencePoint, Geo.distanceMiles(info.point, ref) < 3 else { return false }
        return !info.ugcCodes.isDisjoint(with: Set(a.ugc))
    }

    func inMonitoredArea(_ a: WeatherAlert, zoneMatch zm: Bool) -> Bool {
        if let area = areaPolygon {
            if let g = a.geometry { return Geo.intersects(g, area) || zm }
            return zm
        }
        guard let ref = referencePoint else { return false }
        guard let d = AlertGeo.rangeDistance(a, from: ref, zoneMatch: zm) else { return false }
        return d <= profile.location.radiusMiles
    }

    func isInRange(_ a: WeatherAlert, zoneMatch zm: Bool) -> Bool {
        let rule = profile.rule(for: a.event)
        guard rule.enabled, rule.mode != .off, inMonitoredArea(a, zoneMatch: zm) else { return false }
        if areaPolygon != nil { return true }
        guard let ref = referencePoint, let d = AlertGeo.rangeDistance(a, from: ref, zoneMatch: zm) else { return false }
        return d <= rule.maxDistanceMiles + 0.01
    }

    public func priority(base: Int, for a: WeatherAlert) -> Int {
        let i = profile.interrupts
        if a.isEmergency && i.emergencyAlwaysTop { return 10 }
        var p = base
        if a.isPDS { p += i.pdsBoost }
        if a.thunderstormDamage == .destructive { p += i.destructiveBoost }
        if a.thunderstormDamage == .considerable || a.flashFloodDamage == .considerable { p += i.considerableBoost }
        if a.tornadoDetection == .observed || a.tornadoDetection == .radarConfirmed { p += i.observedTornadoBoost }
        return min(10, max(1, p))
    }

    var phraser: AlertPhraser { AlertPhraser(options: profile.phrasing, template: profile.template) }

    func context(_ a: WeatherAlert, now: Date, verb: AlertVerb, path: PathResult? = nil) -> AlertContext {
        AlertContext(reference: referencePoint, now: now, timeZone: timeZone, zoneMatch: zoneMatch(a), path: path, verb: verb)
    }

    func pathResult(_ a: WeatherAlert, now: Date) -> PathResult? {
        guard let m = a.motion, let ref = referencePoint else { return nil }
        return StormPath.evaluate(motion: m, point: ref, now: now, halfWidthMiles: profile.path.pathHalfWidthMiles)
    }

    func alertDetail(_ a: WeatherAlert) -> String {
        var parts: [String] = []
        if let h = a.headline { parts.append(h) }
        if let h = a.nwsHeadline { parts.append("...\(h)...") }
        parts.append(a.description)
        if let i = a.instruction, !i.isEmpty { parts.append(i) }
        if !a.areaDesc.isEmpty { parts.append("Areas: \(a.areaDesc)") }
        return parts.joined(separator: "\n\n")
    }

    func makeAlertAnnouncement(_ category: AnnouncementCategory, key: String, alert a: WeatherAlert, text: String, now: Date,
                               escalation: Bool = true, priorityOffset: Int = 0, title: String? = nil, toneOverride: ToneID? = nil,
                               modeOverride: AnnounceMode? = nil) -> Announcement {
        let rule = profile.rule(for: a.event)
        var mode = modeOverride ?? rule.mode
        var tone = toneOverride ?? rule.tone
        if !escalation {
            if mode == .toneThenSpeak { mode = .speak; tone = .none }
            if mode == .tone { tone = .blip }
        }
        let pr = priority(base: rule.priority + priorityOffset, for: a)
        let ctx = context(a, now: now, verb: .inEffect)
        return Announcement(
            date: now, category: category, title: title ?? phraser.title(a, ctx), spokenText: text, detailText: alertDetail(a),
            mode: mode, tone: tone, priority: pr,
            canInterrupt: escalation && (rule.canInterrupt || a.isEmergency || a.isPDS),
            notify: rule.notify && settings.general.postNotifications && mode != .off,
            link: a.webLink, eventKey: key, kind: a.event, point: a.geometry.flatMap(Geo.centroid))
    }

    /// Full announcement of an alert (issuance / came into range / read on demand).
    func fullAnnouncement(key: String, _ a: WeatherAlert, verb: AlertVerb, now: Date, prefix: String? = nil) -> Announcement {
        let path = pathResult(a, now: now)
        let showPath = (path?.inPath ?? false) && profile.path.enabled && RiskIndex.score(a) >= profile.path.minimumRisk
        let ctx = context(a, now: now, verb: verb, path: showPath ? path : nil)
        var text = phraser.compose(a, ctx)
        if let p = prefix { text = "\(p) \(text)" }
        if showPath, let eta = path?.etaMinutes {
            let leads = profile.path.leadTimesMinutes
            tracker.update(key) { e in
                for t in leads where Double(t) >= eta { e.pathThresholdsFired.insert(t) }
            }
        }
        return makeAlertAnnouncement(verb == .issued ? .warning : (verb == .updated ? .update : .warning), key: key, alert: a, text: text, now: now)
    }

    func filteredChanges(_ changes: [AlertChange]) -> [AlertChange] {
        let u = profile.updates
        return changes.filter { c in
            switch c {
            case .extended, .shortened: return u.extensions
            case .areaReduced(let pct): return u.areaReduced && pct >= u.areaReducedMinPercent
            case .areasRemoved: return u.areaReduced
            case .areaExpanded, .areasAdded: return u.areaExpanded
            default: return u.threatChanges
            }
        }
    }

    // MARK: Alerts

    func attachZoneGeometry(_ alerts: inout [WeatherAlert]) async {
        var needed: [String] = []
        for a in alerts where a.geometry == nil {
            for z in a.affectedZones where zoneCache[z] == nil && !needed.contains(z) { needed.append(z) }
        }
        if !needed.isEmpty {
            let batch = Array(needed.prefix(40))
            let client = self.client
            let fetched: [(String, GeoShape?)] = await withTaskGroup(of: (String, GeoShape?).self) { group in
                var results: [(String, GeoShape?)] = []
                var iterator = batch.makeIterator()
                for _ in 0..<min(5, batch.count) {
                    if let z = iterator.next() { group.addTask { (z, try? await client.zoneShape(z)) } }
                }
                while let r = await group.next() {
                    results.append(r)
                    if let z = iterator.next() { group.addTask { (z, try? await client.zoneShape(z)) } }
                }
                return results
            }
            for (z, s) in fetched { if let s = s { zoneCache[z] = s } }
        }
        for i in alerts.indices where alerts[i].geometry == nil {
            let polys = alerts[i].affectedZones.compactMap { zoneCache[$0] }.flatMap { $0.polygons }
            if !polys.isEmpty {
                alerts[i].geometry = GeoShape(polygons: polys)
                alerts[i].geometryFromZones = true
            }
        }
    }

    /// Download alerts and turn changes into announcements.
    public func pollAlerts(now: Date = Date()) async -> [Announcement] {
        await refreshPointInfoIfNeeded()
        var alerts: [WeatherAlert]
        do {
            alerts = try await client.activeAlerts(states: alertStates())
            markOK("NWS alerts", count: alerts.count)
        } catch {
            markError("NWS alerts", error)
            return []
        }
        alerts = alerts.filter { let r = profile.rule(for: $0.event); return r.enabled && r.mode != .off }
        await attachZoneGeometry(&alerts)
        return process(alerts: alerts, now: now)
    }

    /// Processing step separated from networking (used by tests and the simulator).
    public func process(alerts: [WeatherAlert], now: Date) -> [Announcement] {
        let life = tracker.ingest(alerts, now: now)
        var out = handle(life, now: now)
        out += evaluateLocation(now: now)
        if needsStartupSummary {
            needsStartupSummary = false
            if profile.startupSummary { out.insert(nearbySummary(now: now, startup: true), at: 0) }
        }
        return out
    }

    func handle(_ life: [AlertLifecycle], now: Date) -> [Announcement] {
        var out: [Announcement] = []
        let u = profile.updates
        for l in life {
            guard let e = tracker.event(l.key) else { continue }
            let a = e.current
            let rule = profile.rule(for: a.event)
            let zm = zoneMatch(a)
            let inRange = isInRange(a, zoneMatch: zm)
            let inside = referencePoint.map { AlertGeo.isInside(a, $0, zoneMatch: zm) } ?? false
            let wasAnnounced = e.announced
            switch l {
            case .initial:
                tracker.update(l.key) { $0.inRange = inRange; $0.userInside = inside; $0.announced = inRange }
            case .issued:
                tracker.update(l.key) { $0.inRange = inRange; $0.userInside = inside; $0.announced = inRange }
                if inRange {
                    out.append(fullAnnouncement(key: l.key, a, verb: e.seenAsNew ? .issued : .inEffect, now: now))
                }
            case .updated(_, _, let changes):
                tracker.update(l.key) { $0.inRange = inRange; $0.userInside = inside }
                if wasAnnounced {
                    guard rule.announceUpdates else { break }
                    let relevant = filteredChanges(changes)
                    let escalated = relevant.contains { $0.isEscalation }
                    if escalated && u.fullMessageOnUpgrade {
                        out.append(fullAnnouncement(key: l.key, a, verb: .updated, now: now, prefix: "Upgraded."))
                    } else if !relevant.isEmpty || u.routineUpdates {
                        let ctx = context(a, now: now, verb: .updated)
                        out.append(makeAlertAnnouncement(.update, key: l.key, alert: a, text: phraser.updateText(a, changes: relevant, ctx),
                                                         now: now, escalation: escalated, priorityOffset: escalated ? 0 : -1))
                    }
                } else if inRange && u.cameIntoRange {
                    tracker.update(l.key) { $0.announced = true }
                    out.append(fullAnnouncement(key: l.key, a, verb: .inEffect, now: now))
                }
            case .partiallyCancelled(_, let cancel, _, let changes):
                tracker.update(l.key) { $0.inRange = inRange; $0.userInside = inside }
                if wasAnnounced && rule.announceEnding && u.cancellations {
                    let ctx = context(a, now: now, verb: .updated)
                    out.append(makeAlertAnnouncement(.update, key: l.key, alert: a,
                                                     text: phraser.partialCancelText(a, cancel: cancel, changes: filteredChanges(changes), ctx),
                                                     now: now, escalation: false, priorityOffset: -2))
                }
            case .cancelled(_, let msg):
                if wasAnnounced && rule.announceEnding && u.cancellations {
                    let ctx = context(a, now: now, verb: .updated)
                    out.append(makeAlertAnnouncement(.update, key: l.key, alert: a,
                                                     text: phraser.cancelText(a, cancel: msg, includeReason: u.cancelReason, ctx),
                                                     now: now, escalation: false, priorityOffset: -2))
                }
            case .expired(_, let msg):
                if wasAnnounced && rule.announceEnding && u.expirations {
                    let ctx = context(a, now: now, verb: .updated)
                    out.append(makeAlertAnnouncement(.update, key: l.key, alert: a, text: phraser.expiredText(a, message: msg, ctx),
                                                     now: now, escalation: false, priorityOffset: -2))
                }
            case .ended:
                if wasAnnounced && rule.announceEnding && (u.cancellations || u.expirations) {
                    let ctx = context(a, now: now, verb: .updated)
                    out.append(makeAlertAnnouncement(.update, key: l.key, alert: a, text: phraser.endedText(a, ctx),
                                                     now: now, escalation: false, priorityOffset: -2))
                }
            case .upgraded(_, let toEvent):
                if wasAnnounced && rule.announceUpdates {
                    let ctx = context(a, now: now, verb: .updated)
                    let text = Spoken.joinSentences(["\(Spoken.capitalizeFirst(phraser.reference(a, ctx))) has been upgraded to \(Spoken.article(for: toEvent)) \(toEvent.lowercased())"])
                    out.append(makeAlertAnnouncement(.update, key: l.key, alert: a, text: text, now: now, escalation: false, priorityOffset: -1))
                }
            }
        }
        return out
    }

    /// Range, inside/outside and path checks for every active alert against the current reference point.
    func evaluateLocation(now: Date) -> [Announcement] {
        guard let ref = referencePoint else { return [] }
        var out: [Announcement] = []
        let u = profile.updates
        let ps = profile.path
        for e in tracker.activeEvents {
            let a = e.current
            let rule = profile.rule(for: a.event)
            guard rule.enabled, rule.mode != .off else { continue }
            let zm = zoneMatch(a)
            let inRange = isInRange(a, zoneMatch: zm)
            let inside = AlertGeo.isInside(a, ref, zoneMatch: zm)
            var announced = e.announced
            var enteredNow = false

            if usingGPS && inside != e.userInside {
                if inside && u.enteredWarning {
                    let ctx = context(a, now: now, verb: .inEffect)
                    out.append(makeAlertAnnouncement(.location, key: e.key, alert: a, text: phraser.enteredText(a, details: u.enteredWarningDetails, ctx),
                                                     now: now, title: "Entered \(a.event)"))
                    announced = true
                    enteredNow = true
                } else if !inside && u.leftWarning && announced {
                    let ctx = context(a, now: now, verb: .inEffect)
                    out.append(makeAlertAnnouncement(.location, key: e.key, alert: a, text: phraser.leftText(a, ctx), now: now,
                                                     escalation: false, priorityOffset: -2, title: "Left \(a.event)"))
                }
            }
            if inRange != e.inRange {
                if inRange && !announced && !enteredNow && u.cameIntoRange {
                    out.append(fullAnnouncement(key: e.key, a, verb: .inEffect, now: now))
                    announced = true
                } else if !inRange && announced && u.wentOutOfRange && !inside {
                    let ctx = context(a, now: now, verb: .inEffect)
                    let text = Spoken.joinSentences(["\(Spoken.capitalizeFirst(phraser.reference(a, ctx))) is now out of range"])
                    out.append(makeAlertAnnouncement(.update, key: e.key, alert: a, text: text, now: now, escalation: false, priorityOffset: -3))
                }
            }

            var fired = tracker.event(e.key)?.pathThresholdsFired ?? e.pathThresholdsFired
            var lastETA: Double? = nil
            if ps.enabled, ps.mode != .off, a.motion != nil, RiskIndex.score(a) >= ps.minimumRisk, inMonitoredArea(a, zoneMatch: zm),
               let pr = pathResult(a, now: now), pr.inPath, let eta = pr.etaMinutes, !ps.onlyInsideWarning || inside {
                lastETA = eta
                let newly = ps.leadTimesMinutes.filter { Double($0) >= eta && !fired.contains($0) }
                if !newly.isEmpty {
                    for t in ps.leadTimesMinutes where Double(t) >= eta { fired.insert(t) }
                    let ctx = context(a, now: now, verb: .inEffect, path: pr)
                    var ann = makeAlertAnnouncement(.path, key: e.key, alert: a, text: phraser.pathText(a, path: pr, ctx), now: now,
                                                    title: "In path: \(a.event) · ~\(Int(eta.rounded())) min", toneOverride: ps.tone, modeOverride: ps.mode)
                    ann.priority = max(ann.priority, priority(base: ps.priority, for: a))
                    out.append(ann)
                }
            }
            tracker.update(e.key) {
                $0.inRange = inRange
                $0.userInside = inside
                $0.announced = announced
                $0.pathThresholdsFired = fired
                $0.lastPathETA = lastETA
            }
        }
        return out
    }

    // MARK: Lists for the UI

    public func activeAlertInfos(now: Date = Date()) -> [ActiveAlertInfo] {
        let ref = referencePoint
        return tracker.activeEvents.map { e in
            let a = e.current
            let zm = zoneMatch(a)
            let ctx = context(a, now: now, verb: .inEffect)
            let pos = ref.flatMap { AlertGeo.position(of: a, from: $0, measure: .nearestEdge, now: now, zoneMatch: zm) }
            let pr = pathResult(a, now: now)
            return ActiveAlertInfo(id: e.key, alert: a, title: phraser.title(a, ctx), distanceMiles: pos?.miles, bearing: pos?.bearing,
                                   inside: pos?.inside ?? false, inRange: isInRange(a, zoneMatch: zm), risk: RiskIndex.score(a),
                                   path: (pr?.inPath ?? false) ? pr : nil, priority: priority(base: profile.rule(for: a.event).priority, for: a))
        }.sorted { ($0.priority, -($0.distanceMiles ?? 9999)) > ($1.priority, -($1.distanceMiles ?? 9999)) }
    }

    /// "There are 2 alerts in range..." followed by each one.
    public func nearbySummary(now: Date = Date(), startup: Bool = false) -> Announcement {
        let infos = activeAlertInfos(now: now).filter { $0.inRange }
        var parts: [String] = []
        if startup { parts.append("Storm Radio is monitoring, profile \(profile.name)") }
        if infos.isEmpty {
            parts.append(referencePoint == nil ? "Waiting for a location" : "No active alerts in range")
        } else {
            let counts = Dictionary(grouping: infos, by: { $0.alert.event }).map { (k, v) in "\(v.count) \(k.lowercased())\(v.count > 1 ? "s" : "")" }
            parts.append("Active in range: \(Spoken.list(counts.sorted()))")
            for info in infos.prefix(6) {
                let ctx = context(info.alert, now: now, verb: .inEffect, path: info.path)
                parts.append(phraser.compose(info.alert, ctx))
            }
            if infos.count > 6 { parts.append("And \(infos.count - 6) more") }
        }
        let text = parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
        return Announcement(date: now, category: .summary, title: startup ? "Monitoring started · \(profile.name)" : "Nearby alerts summary",
                            spokenText: text, detailText: text, mode: .speak, priority: 5, notify: false)
    }

    // MARK: Storm reports

    func reportInArea(_ r: StormReport) -> Bool {
        if let area = areaPolygon { return Geo.contains(area, r.point) }
        guard let ref = referencePoint else { return false }
        return Geo.distanceMiles(ref, r.point) <= min(profile.location.radiusMiles, profile.reports.maxDistanceMiles)
    }

    public func pollReports(now: Date = Date()) async -> [Announcement] {
        let rs = profile.reports
        guard rs.enabled else { return [] }
        await refreshPointInfoIfNeeded()
        var all: [StormReport] = []
        if rs.sourceEnabled(.nwsLSR) {
            do {
                let states = pointInfo?.state.map { StateNeighbors.withNeighbors([$0]) }
                let r = try await client.localStormReports(hours: max(2, rs.maxAgeMinutes / 60 + 1), states: settings.general.limitToNearbyStates ? states : nil)
                all += r
                markOK("NWS storm reports", count: r.count)
            } catch { markError("NWS storm reports", error) }
        }
        if rs.sourceEnabled(.spotterNetwork) {
            do {
                let r = try await client.spotterNetworkReports()
                all += r
                markOK("SpotterNetwork", count: r.count)
            } catch { markError("SpotterNetwork", error) }
        }
        if rs.sourceEnabled(.mping) && !settings.general.mpingAPIKey.isEmpty {
            do {
                let r = try await client.mpingReports(since: now.addingTimeInterval(-Double(max(rs.maxAgeMinutes, 60)) * 60))
                all += r
                markOK("mPING", count: r.count)
            } catch { markError("mPING", error) }
        }
        return process(reports: all, now: now)
    }

    public func process(reports all: [StormReport], now: Date) -> [Announcement] {
        let rs = profile.reports
        for r in all { reports[r.id] = r }
        reports = reports.filter { now.timeIntervalSince($0.value.eventTime) < 6 * 3600 }
        let fresh = all.filter { !seenReports.contains($0.id) }
        for r in fresh { seenReports.insert(r.id) }
        guard reportsInitialized else { reportsInitialized = true; return [] }

        let phr = ReportPhraser(settings: rs, phrasing: profile.phrasing)
        var out: [Announcement] = []
        for r in fresh.sorted(by: { $0.eventTime < $1.eventTime }) {
            let rule = rs.rule(for: r.category)
            guard rule.enabled, rule.mode != .off else { continue }
            if rule.minMagnitude > 0, r.category == .hail || r.category == .windGust {
                guard let m = r.magnitude, m >= rule.minMagnitude else { continue }
            }
            guard now.timeIntervalSince(r.eventTime) <= Double(rs.maxAgeMinutes) * 60, reportInArea(r) else { continue }
            let dup = announcedReports.contains { o in
                o.category == r.category && o.source != r.source && Geo.distanceMiles(o.point, r.point) < 3 && abs(o.eventTime.timeIntervalSince(r.eventTime)) < 900
            }
            if dup { continue }
            announcedReports.append(r)
            out.append(Announcement(
                date: now, category: .report, title: phr.title(r, from: referencePoint),
                spokenText: phr.compose(r, from: referencePoint, now: now, timeZone: timeZone),
                detailText: reportDetail(r), mode: rule.mode, tone: rule.tone, priority: rule.priority, canInterrupt: false,
                notify: settings.general.postNotifications && rule.mode != .off, link: r.webLink, kind: r.category.rawValue, point: r.point))
        }
        announcedReports = announcedReports.filter { now.timeIntervalSince($0.eventTime) < 3600 }
        if out.count > 6 {
            let extra = out.count - 5
            out = Array(out.sorted { $0.priority > $1.priority }.prefix(5))
            out.append(Announcement(date: now, category: .report, title: "+\(extra) more reports", spokenText: "And \(extra) more storm reports.",
                                    mode: .speak, priority: 3, notify: false))
        }
        return out
    }

    func reportDetail(_ r: StormReport) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.timeZone = timeZone
        var lines = ["\(r.source.label): \(r.typeText)"]
        if let m = r.magnitude { lines.append("Magnitude: \(m) \(r.unit ?? "")\(r.measured == true ? " (measured)" : r.measured == false ? " (estimated)" : "")") }
        if let p = r.place { lines.append("Location: \(p)\(r.county.map { ", \($0) County" } ?? "")\(r.state.map { ", \($0)" } ?? "")") }
        if let who = r.reporter { lines.append("Reported by: \(who)") }
        lines.append("Happened: \(f.string(from: r.eventTime))")
        if let rel = r.releasedTime { lines.append("Released: \(f.string(from: rel))\(r.delayMinutes.map { $0 >= 5 ? " (\($0) min later)" : "" } ?? "")") }
        if let rem = r.remark, !rem.isEmpty { lines.append("Remarks: \(rem)") }
        return lines.joined(separator: "\n")
    }

    public func recentReports(now: Date = Date(), minutes: Int = 60) -> [StormReport] {
        reports.values.filter { now.timeIntervalSince($0.eventTime) <= Double(minutes) * 60 && reportInArea($0) }
            .sorted { $0.eventTime > $1.eventTime }
    }

    public func reportsSummary(now: Date = Date()) -> Announcement {
        let rs = recentReports(now: now, minutes: profile.reports.maxAgeMinutes)
        let phr = ReportPhraser(settings: profile.reports, phrasing: profile.phrasing)
        var text: String
        if rs.isEmpty { text = "No storm reports in range in the last \(Spoken.duration(minutes: profile.reports.maxAgeMinutes))." }
        else {
            text = "\(Spoken.plural(rs.count, "storm report")) in range in the last \(Spoken.duration(minutes: profile.reports.maxAgeMinutes)). "
            text += rs.prefix(5).map { phr.compose($0, from: referencePoint, now: now, timeZone: timeZone) }.joined(separator: " ")
        }
        return Announcement(date: now, category: .summary, title: "Storm reports summary", spokenText: text, detailText: text, priority: 4, notify: false)
    }

    // MARK: SPC products

    public func pollSPC(now: Date = Date()) async -> [Announcement] {
        var out: [Announcement] = []
        let spc = profile.spc
        let ref = referencePoint

        // Mesoscale discussions
        do {
            let refs = try await client.products(type: "SWO", location: "MCD")
            for pr in refs.prefix(8) where !seenProducts.contains(pr.id) && now.timeIntervalSince(pr.issued) < 8 * 3600 {
                let text = try await client.productText(id: pr.id)
                seenProducts.insert(pr.id)
                guard let md = MesoscaleDiscussion.parse(text, id: pr.id, issued: pr.issued) else { continue }
                mds.append(md)
                guard initializedFeeds.contains("MCD"), spc.mdEnabled, spc.mdMode != .off, now.timeIntervalSince(pr.issued) < 3600 else { continue }
                var near = spc.mdNationwide
                if !near, let r = ref, let s = md.shape, let d = Geo.distance(from: r, to: s) { near = d.miles <= spc.mdMaxDistanceMiles }
                guard near else { continue }
                out.append(Announcement(date: now, category: .md, title: "MD \(md.number): \(md.areasAffected)",
                                        spokenText: md.announcement(from: ref, compass: profile.phrasing.compass, readSummary: spc.mdReadSummary),
                                        detailText: md.rawText, mode: spc.mdMode, tone: spc.mdTone, priority: spc.mdPriority,
                                        notify: settings.general.postNotifications, link: md.link, kind: "MD",
                                        point: md.shape.flatMap(Geo.centroid)))
            }
            mds = Array(mds.sorted { $0.issued > $1.issued }.prefix(20))
            initializedFeeds.insert("MCD")
            markOK("SPC mesoscale discussions", count: mds.count)
        } catch { markError("SPC mesoscale discussions", error) }

        // Watches (SPC SEL products)
        do {
            let refs = try await client.products(type: "SEL")
            for pr in refs.prefix(6) where !seenProducts.contains(pr.id) && now.timeIntervalSince(pr.issued) < 12 * 3600 {
                let text = try await client.productText(id: pr.id)
                seenProducts.insert(pr.id)
                guard let w = SPCWatch.parse(text, id: pr.id, issued: pr.issued) else { continue }
                watches.append(w)
                guard initializedFeeds.contains("SEL"), spc.watchEnabled, spc.watchMode != .off, now.timeIntervalSince(pr.issued) < 3600 else { continue }
                out.append(Announcement(date: now, category: .watch, title: "\(w.isPDS ? "PDS " : "")\(w.type) \(w.number)",
                                        spokenText: w.announcement(readThreats: spc.watchReadThreats), detailText: w.rawText,
                                        mode: spc.watchMode, tone: spc.watchTone, priority: min(10, spc.watchPriority + (w.isPDS ? 2 : 0)),
                                        canInterrupt: w.isPDS, notify: settings.general.postNotifications, link: w.link, kind: w.type))
            }
            watches = Array(watches.sorted { $0.issued > $1.issued }.prefix(20))
            initializedFeeds.insert("SEL")
            markOK("SPC watches", count: watches.count)
        } catch { markError("SPC watches", error) }

        // Convective outlooks
        let days = Set(spc.outlookDays + [1]).sorted()
        for day in days where (1...3).contains(day) {
            let feed = "DY\(day)"
            do {
                let refs = try await client.products(type: "SWO", location: feed)
                guard let newest = refs.first else { continue }
                if outlooks[day]?.id != newest.id {
                    let text = try await client.productText(id: newest.id)
                    var o = OutlookSummary.parse(text, day: day, id: newest.id, issued: newest.issued)
                    var layers: [String: OutlookLayer] = [:]
                    for kind in day == 3 ? ["cat", "prob"] : ["cat", "torn", "wind", "hail"] {
                        if let l = try? await client.outlookLayer(day: day, kind: kind) { layers[kind] = l }
                    }
                    outlookLayers[day] = layers
                    if let catMax = layers["cat"]?.maxCategory, catMax > o.maxCategory { o.maxCategory = catMax }
                    fillMyRisk(&o)
                    outlooks[day] = o
                    if initializedFeeds.contains(feed), spc.outlookEnabled, spc.outlookDays.contains(day), spc.outlookMode != .off,
                       o.maxCategory >= spc.outlookMinimumRisk, now.timeIntervalSince(newest.issued) < 3600 {
                        out.append(Announcement(date: now, category: .outlook, title: "SPC Day \(day) outlook · \(o.maxCategory.label)",
                                                spokenText: o.announcement(sayMyRisk: spc.outlookSayMyRisk, readSummary: spc.outlookReadSummary),
                                                detailText: o.rawText, mode: spc.outlookMode, tone: spc.outlookTone, priority: spc.outlookPriority,
                                                notify: settings.general.postNotifications, link: o.link, kind: "Outlook"))
                    }
                }
                initializedFeeds.insert(feed)
                markOK("SPC outlooks", count: outlooks.count)
            } catch { markError("SPC outlooks", error) }
        }
        return out
    }

    func fillMyRisk(_ o: inout OutlookSummary) {
        guard let ref = referencePoint, let layers = outlookLayers[o.day] else { return }
        o.myCategory = layers["cat"]?.category(at: ref)
        if o.day == 3 {
            o.mySevere = layers["prob"]?.probability(at: ref)
        } else {
            o.myTornado = layers["torn"]?.probability(at: ref)
            o.myWind = layers["wind"]?.probability(at: ref)
            o.myHail = layers["hail"]?.probability(at: ref)
        }
    }

    public func outlookAnnouncement(day: Int, now: Date = Date()) -> Announcement {
        guard var o = outlooks[day] else {
            return Announcement(date: now, category: .summary, title: "Day \(day) outlook", spokenText: "The day \(day) outlook has not been downloaded yet.", priority: 3, notify: false)
        }
        fillMyRisk(&o)
        return Announcement(date: now, category: .summary, title: "SPC Day \(day) outlook · \(o.maxCategory.label)",
                            spokenText: o.announcement(sayMyRisk: true, readSummary: true), detailText: o.rawText,
                            priority: 3, notify: false, link: o.link, kind: "Outlook")
    }

    /// Reads the most recent mesoscale discussion (the nearest recent one if `nearest`).
    public func mdAnnouncement(now: Date = Date(), nearest: Bool = false) -> Announcement {
        let recent = mds.filter { now.timeIntervalSince($0.issued) < 4 * 3600 }
        var pick = recent.first
        if nearest, let ref = referencePoint {
            pick = recent.min { a, b in
                let da = a.shape.flatMap { Geo.distance(from: ref, to: $0)?.miles } ?? .infinity
                let db = b.shape.flatMap { Geo.distance(from: ref, to: $0)?.miles } ?? .infinity
                return da < db
            }
        }
        guard let md = pick else {
            return Announcement(date: now, category: .summary, title: "Mesoscale discussions", spokenText: "No mesoscale discussions in the last 4 hours.", priority: 3, notify: false)
        }
        return Announcement(date: now, category: .summary, title: "MD \(md.number): \(md.areasAffected)",
                            spokenText: md.announcement(from: referencePoint, compass: profile.phrasing.compass, readSummary: true),
                            detailText: md.rawText, priority: 3, notify: false, link: md.link, kind: "MD")
    }

    public func watchAnnouncement(now: Date = Date()) -> Announcement {
        let recent = watches.filter { now.timeIntervalSince($0.issued) < 8 * 3600 }
        guard !recent.isEmpty else {
            return Announcement(date: now, category: .summary, title: "SPC watches", spokenText: "No new watches from S P C in the last 8 hours.", priority: 3, notify: false)
        }
        let text = recent.prefix(4).map { $0.announcement(readThreats: true) }.joined(separator: " ")
        return Announcement(date: now, category: .summary, title: "Recent SPC watches", spokenText: text, detailText: recent.map { $0.rawText }.joined(separator: "\n\n"), priority: 3, notify: false)
    }

    // MARK: Area forecast discussions

    var afdOffices: [String] {
        var out: [String] = []
        if profile.afd.includeLocalOffice, let cwa = pointInfo?.cwa, !cwa.isEmpty { out.append(cwa) }
        for o in profile.afd.extraOffices.map({ $0.uppercased().trimmingCharacters(in: .whitespaces) }) where !o.isEmpty && !out.contains(o) { out.append(o) }
        return out
    }

    static func officeName(from text: String) -> String? {
        for line in text.split(separator: "\n").prefix(12) where line.hasPrefix("National Weather Service ") {
            var name = line.dropFirst("National Weather Service ".count).trimmingCharacters(in: .whitespaces)
            if name.count > 3, name.dropLast(2).hasSuffix(" ") { name = String(name.dropLast(3)) }
            return name
        }
        return nil
    }

    public func pollAFD(now: Date = Date()) async -> [Announcement] {
        let s = profile.afd
        guard s.enabled else { return [] }
        await refreshPointInfoIfNeeded()
        var out: [Announcement] = []
        for office in afdOffices {
            do {
                let refs = try await client.products(type: "AFD", location: office)
                guard let newest = refs.first else { continue }
                if afds[office]?.id != newest.id {
                    let text = try await client.productText(id: newest.id)
                    let afd = AreaForecastDiscussion.parse(text, office: office, id: newest.id, issued: newest.issued)
                    afds[office] = afd
                    let feed = "AFD-\(office)"
                    if initializedFeeds.contains(feed), s.mode != .off, now.timeIntervalSince(newest.issued) < 3600 {
                        let name = Self.officeName(from: text) ?? office
                        var spoken = "New area forecast discussion from the National Weather Service in \(name)."
                        if !s.readSectionsOnIssue.isEmpty { spoken = afd.spoken(sections: s.readSectionsOnIssue, officeName: name) }
                        out.append(Announcement(date: now, category: .afd, title: "AFD · \(name)", spokenText: spoken, detailText: text,
                                                mode: s.mode, tone: s.tone, priority: s.priority, notify: settings.general.postNotifications,
                                                link: afd.link, kind: "AFD"))
                    }
                    initializedFeeds.insert(feed)
                } else {
                    initializedFeeds.insert("AFD-\(office)")
                }
                markOK("Forecast discussions", count: afds.count)
            } catch { markError("Forecast discussions", error) }
        }
        return out
    }

    public func afdAnnouncement(now: Date = Date()) -> Announcement {
        let office = afdOffices.first
        guard let o = office, let afd = afds[o] else {
            return Announcement(date: now, category: .summary, title: "Area forecast discussion", spokenText: "No forecast discussion downloaded yet.", priority: 2, notify: false)
        }
        let name = Self.officeName(from: afd.rawText) ?? o
        return Announcement(date: now, category: .summary, title: "AFD · \(name)",
                            spokenText: afd.spoken(sections: profile.afd.readSectionsOnDemand, officeName: name),
                            detailText: afd.rawText, priority: 2, notify: false, link: afd.link, kind: "AFD")
    }
}
