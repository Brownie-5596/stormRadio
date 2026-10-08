import SwiftUI
import UIKit
import CoreLocation
import Combine
import StormRadioCore

/// App-wide state: settings, the monitor loop, the feed and the speech queue.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { settingsChanged() }
    }
    @Published private(set) var feed: [Announcement] = []
    @Published private(set) var activeAlerts: [ActiveAlertInfo] = []
    @Published private(set) var reports: [StormReport] = []
    @Published private(set) var mds: [MesoscaleDiscussion] = []
    @Published private(set) var sourceStatus: [String: SourceStatus] = [:]
    @Published private(set) var pointInfo: PointInfo?
    @Published private(set) var lastAlertPoll: Date?
    @Published var monitoring = false
    @Published var snoozedUntil: Date?
    @Published var selectedTab: Tab = .radio
    @Published var openAnnouncementID: String?

    enum Tab: Hashable { case radio, feed, map, settings }

    let speech = SpeechCenter()
    let location = LocationService()
    private let monitor: StormMonitor
    private var loopTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var lastPoll: [String: Date] = [:]
    private var lastLocationSent: CLLocation?
    private var pendingLocation: CLLocation?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let s = Storage.loadSettings()
        settings = s
        monitor = StormMonitor(settings: s)
        feed = Storage.loadFeed()
        applyLocalSettings()
        Task { [monitor] in await monitor.setZoneCache(Storage.loadZones()) }
        location.onUpdate = { [weak self] loc in self?.locationChanged(loc) }
        NotificationService.shared.onOpen = { [weak self] id in
            self?.openAnnouncementID = id
            self?.selectedTab = .feed
        }
        // Re-publish speech changes so views observing the model refresh.
        speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        location.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var profile: Profile {
        get { settings.activeProfile }
        set { settings.activeProfile = newValue }
    }

    /// A binding to one profile by id (safe even if the profile list changes).
    func binding(for id: String) -> Binding<Profile> {
        Binding(
            get: { self.settings.profiles.first(where: { $0.id == id }) ?? self.settings.activeProfile },
            set: { new in
                if let i = self.settings.profiles.firstIndex(where: { $0.id == id }) { self.settings.profiles[i] = new }
            })
    }

    var activeProfileBinding: Binding<Profile> { binding(for: settings.activeProfileID) }

    // MARK: Settings

    private func settingsChanged() {
        applyLocalSettings()
        saveTask?.cancel()
        saveTask = Task { [settings] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            Storage.save(settings)
        }
        applyTask?.cancel()
        applyTask = Task { [settings, monitor] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await monitor.apply(settings: settings)
        }
        if monitoring { location.start(precise: profile.location.mode == .gps) }
    }

    private func applyLocalSettings() {
        speech.voice = profile.voice
        speech.interrupts = profile.interrupts
        speech.keepAlive = monitoring && settings.general.keepAliveAudio
        UIApplication.shared.isIdleTimerDisabled = monitoring && settings.general.keepScreenOn
    }

    func switchProfile(to id: String) {
        guard id != settings.activeProfileID else { return }
        settings.activeProfileID = id
        if monitoring {
            Task { [monitor, settings] in
                await monitor.apply(settings: settings)
                await monitor.requestStartupSummary()
            }
            lastPoll["alerts"] = nil
        }
    }

    func replaceSettings(_ new: AppSettings) {
        settings = new
        Task { [monitor, new] in await monitor.apply(settings: new) }
    }

    // MARK: Monitoring

    func toggleMonitoring() {
        monitoring ? stopMonitoring() : startMonitoring()
    }

    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        NotificationService.shared.requestPermission()
        location.start(precise: profile.location.mode == .gps)
        applyLocalSettings()
        lastPoll = [:]
        Task { [monitor] in await monitor.requestStartupSummary() }
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        monitoring = false
        loopTask?.cancel()
        loopTask = nil
        location.stop()
        applyLocalSettings()
        speech.stopAll()
    }

    private func due(_ key: String, every seconds: Int, now: Date) -> Bool {
        guard let last = lastPoll[key] else { return true }
        return now.timeIntervalSince(last) >= Double(max(10, seconds))
    }

    private var lastSnapshot = Date.distantPast
    private var lastZoneSave = Date()

    private func tick() async {
        let now = Date()
        let g = settings.general
        var didWork = false
        if let loc = pendingLocation {
            pendingLocation = nil
            let p = GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            deliver(await monitor.updateLocation(p, now: now))
            didWork = true
        }
        if due("alerts", every: g.alertPollSeconds, now: now) {
            lastPoll["alerts"] = now
            deliver(await monitor.pollAlerts(now: now))
            lastAlertPoll = Date()
            didWork = true
        }
        if due("reports", every: g.reportPollSeconds, now: now) {
            lastPoll["reports"] = now
            deliver(await monitor.pollReports(now: now))
            didWork = true
        }
        if due("spc", every: g.productPollSeconds, now: now) {
            lastPoll["spc"] = now
            deliver(await monitor.pollSPC(now: now))
            didWork = true
        }
        if due("afd", every: g.afdPollSeconds, now: now) {
            lastPoll["afd"] = now
            deliver(await monitor.pollAFD(now: now))
            didWork = true
        }
        // Snapshots for the UI: after any work, and every 20 s so countdowns stay fresh.
        if didWork || now.timeIntervalSince(lastSnapshot) > 20 {
            lastSnapshot = now
            await refreshSnapshots()
        }
        if now.timeIntervalSince(lastZoneSave) > 300 {
            lastZoneSave = now
            Storage.save(zones: await monitor.zoneCache)
        }
    }

    func refreshSnapshots() async {
        activeAlerts = await monitor.activeAlertInfos()
        reports = await monitor.recentReports(minutes: 180)
        mds = await monitor.mds
        sourceStatus = await monitor.status
        pointInfo = await monitor.pointInfo
    }

    /// Force all feeds to refresh on the next tick.
    func refreshNow() {
        lastPoll = [:]
        if !monitoring { startMonitoring() }
    }

    private func locationChanged(_ loc: CLLocation) {
        guard profile.location.mode == .gps || profile.location.fixedPoint == nil else { return }
        if let last = lastLocationSent, loc.distance(from: last) < 150 { return }
        lastLocationSent = loc
        pendingLocation = loc
    }

    // MARK: Announcements

    var isSnoozed: Bool { (snoozedUntil ?? .distantPast) > Date() }

    func snooze(minutes: Int) {
        snoozedUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        if minutes > 0 { speech.stopAll() }
    }

    private func deliver(_ list: [Announcement]) {
        guard !list.isEmpty else { return }
        for a in list {
            feed.insert(a, at: 0)
            let snoozed = isSnoozed && a.priority < 9
            if !snoozed { speech.enqueue(a) }
            if a.notify && settings.general.postNotifications { NotificationService.shared.post(a) }
        }
        if feed.count > 500 { feed.removeLast(feed.count - 500) }
        Storage.save(feed: feed)
    }

    /// Speak something on demand (and log it in the feed).
    func say(_ a: Announcement) {
        feed.insert(a, at: 0)
        Storage.save(feed: feed)
        speech.speakNow(a)
    }

    func readNearby() { Task { say(await monitor.nearbySummary()) } }
    func readLatestMD(nearest: Bool = false) { Task { say(await monitor.mdAnnouncement(nearest: nearest)) } }
    func readOutlook(day: Int) { Task { say(await monitor.outlookAnnouncement(day: day)) } }
    func readAFD() { Task { say(await monitor.afdAnnouncement()) } }
    func readReports() { Task { say(await monitor.reportsSummary()) } }
    func readWatches() { Task { say(await monitor.watchAnnouncement()) } }

    func readAlert(_ info: ActiveAlertInfo) {
        let ph = AlertPhraser(options: profile.phrasing, template: profile.template)
        let ref = currentReferencePoint
        let ctx = AlertContext(reference: ref, now: Date(), zoneMatch: info.inside && info.alert.geometry == nil, path: info.path, verb: .inEffect)
        say(Announcement(date: Date(), category: .summary, title: info.title, spokenText: ph.compose(info.alert, ctx),
                         detailText: info.alert.description, priority: 5, notify: false, link: info.alert.webLink,
                         eventKey: info.id, kind: info.alert.event))
    }

    func clearFeed() {
        feed.removeAll()
        Storage.save(feed: feed)
        NotificationService.shared.clearDelivered()
    }

    func deleteFeedItems(_ ids: Set<String>) {
        feed.removeAll { ids.contains($0.id) }
        Storage.save(feed: feed)
    }

    var currentReferencePoint: GeoPoint? {
        let loc = profile.location
        let gps = location.location.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        switch loc.mode {
        case .fixed: return loc.fixedPoint ?? gps
        case .gps: return gps ?? loc.fixedPoint
        }
    }

    var locationDescription: String {
        let loc = profile.location
        var s: String
        switch loc.mode {
        case .gps:
            if let l = location.location {
                s = String(format: "GPS %.3f, %.3f", l.coordinate.latitude, l.coordinate.longitude)
            } else {
                s = "Waiting for GPS…"
            }
        case .fixed:
            if let p = loc.fixedPoint {
                s = loc.fixedName.isEmpty ? String(format: "Fixed %.3f, %.3f", p.lat, p.lon) : "Fixed: \(loc.fixedName)"
            } else {
                s = "Fixed point not set (using GPS)"
            }
        }
        if let info = pointInfo, let city = info.city { s += " · near \(city), \(info.state ?? "")" }
        if loc.areaMode == .polygon && loc.polygon.count >= 3 {
            s += " · area: \(loc.polygonName.isEmpty ? "custom polygon" : loc.polygonName)"
        } else {
            s += " · \(Int(loc.radiusMiles)) mi radius"
        }
        return s
    }
}
