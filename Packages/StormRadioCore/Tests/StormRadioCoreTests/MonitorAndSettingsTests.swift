import XCTest
@testable import StormRadioCore

final class MonitorAndSettingsTests: XCTestCase {
    func monitor(at p: GeoPoint, mode: LocationMode = .fixed) -> StormMonitor {
        var s = AppSettings.defaults
        var prof = s.activeProfile
        prof.location.mode = mode
        prof.location.fixedPoint = mode == .fixed ? p : nil
        prof.startupSummary = false
        s.activeProfile = prof
        let m = StormMonitor(settings: s)
        m.timeZone = TimeZone(identifier: "UTC")!
        if mode == .gps { _ = m.updateLocation(p, now: Date()) }
        return m
    }

    func testIssueUpdateCancelFlow() {
        let now = date("2026-05-06T23:40:00Z")
        let m = monitor(at: GeoPoint(lat: 35.2, lon: -97.5)) // ~6 miles west of the test polygon
        XCTAssertTrue(m.process(alerts: [], now: now).isEmpty)

        var a = makeAlert(sent: now)
        a.maxWindMPH = 60
        a.windBasis = .radarIndicated
        let issued = m.process(alerts: [a], now: now.addingTimeInterval(20))
        XCTAssertEqual(issued.count, 1)
        XCTAssertEqual(issued[0].category, .warning)
        XCTAssertTrue(issued[0].spokenText.hasPrefix("A severe thunderstorm warning was issued 6 miles to the east."), issued[0].spokenText)
        XCTAssertEqual(issued[0].mode, .toneThenSpeak)
        XCTAssertEqual(issued[0].tone, .tripleBeep)

        // Update: hail observed.
        var u = a
        u.id = "update-1"
        u.vtec[0].action = .con
        u.sent = now.addingTimeInterval(600)
        u.maxHailInches = 1.75
        u.hailBasis = .observed
        let upd = m.process(alerts: [u], now: now.addingTimeInterval(620))
        XCTAssertEqual(upd.count, 1)
        XCTAssertTrue(upd[0].spokenText.hasPrefix("Upgraded."), upd[0].spokenText)
        XCTAssertTrue(upd[0].spokenText.contains("golf ball size hail was observed"), upd[0].spokenText)

        // Cancel.
        var c = u
        c.id = "cancel-1"
        c.vtec[0].action = .can
        c.messageType = "Cancel"
        c.sent = now.addingTimeInterval(1200)
        c.description = "The storm which prompted the warning has weakened below severe limits, and no longer poses an immediate threat to life or property.\n\n"
        let can = m.process(alerts: [c], now: now.addingTimeInterval(1220))
        XCTAssertEqual(can.count, 1)
        XCTAssertEqual(can[0].spokenText, "The severe thunderstorm warning 6 miles east has been cancelled. The storm which prompted the warning has weakened below severe limits, and no longer poses an immediate threat to life or property.")
        XCTAssertFalse(can[0].canInterrupt)
    }

    func testOutOfRangeIsSilentButTracked() {
        let now = date("2026-05-06T23:40:00Z")
        let m = monitor(at: GeoPoint(lat: 36.5, lon: -97.3)) // ~85 miles north
        _ = m.process(alerts: [], now: now)
        let out = m.process(alerts: [makeAlert(sent: now)], now: now.addingTimeInterval(10))
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(m.tracker.activeEvents.count, 1)
        XCTAssertFalse(m.activeAlertInfos(now: now).first!.inRange)
    }

    func testEnteredAndLeftWarningWithGPS() {
        let now = date("2026-05-06T23:40:00Z")
        let m = monitor(at: GeoPoint(lat: 35.2, lon: -97.6), mode: .gps)
        _ = m.process(alerts: [], now: now)
        _ = m.process(alerts: [makeAlert(sent: now)], now: now.addingTimeInterval(10))
        let entered = m.updateLocation(GeoPoint(lat: 35.2, lon: -97.3), now: now.addingTimeInterval(300))
        XCTAssertEqual(entered.count, 1)
        XCTAssertEqual(entered[0].category, .location)
        XCTAssertTrue(entered[0].spokenText.hasPrefix("You have entered a severe thunderstorm warning."), entered[0].spokenText)
        XCTAssertTrue(m.updateLocation(GeoPoint(lat: 35.21, lon: -97.31), now: now.addingTimeInterval(320)).isEmpty)
        let left = m.updateLocation(GeoPoint(lat: 35.2, lon: -97.1), now: now.addingTimeInterval(900))
        XCTAssertEqual(left.first?.spokenText, "You have left the severe thunderstorm warning.")
    }

    func testPathAlertFiresOncePerThreshold() {
        let now = date("2026-05-06T23:40:00Z")
        let user = GeoPoint(lat: 35.2, lon: -97.0) // east of the polygon
        let m = monitor(at: user)
        _ = m.process(alerts: [], now: now)
        var a = makeAlert(event: "Tornado Warning", sent: now)
        a.tornadoDetection = .radarIndicated
        let stormPos = Geo.destination(from: user, bearingDegrees: 270, miles: 18)
        a.motion = StormMotion(time: now, fromDegrees: 270, speedKnots: 39, points: [stormPos]) // 45 mph -> 24 min
        let first = m.process(alerts: [a], now: now.addingTimeInterval(5))
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].spokenText.contains("You are in the path"), first[0].spokenText)
        // Same poll again a minute later: the 30-minute threshold already fired with the issuance.
        XCTAssertTrue(m.process(alerts: [a], now: now.addingTimeInterval(65)).filter { $0.category == .path }.isEmpty)
        // 10 minutes later (ETA ~14 min) the 15-minute threshold fires.
        let later = m.process(alerts: [a], now: now.addingTimeInterval(600))
        XCTAssertEqual(later.filter { $0.category == .path }.count, 1, "\(later.map { $0.spokenText })")
    }

    func testSettingsRoundTripAndLenientImport() throws {
        let s = AppSettings.defaults
        let data = try SettingsIO.encode(s)
        let back = try SettingsIO.decode(data)
        XCTAssertEqual(back, s)

        // Remove a bunch of keys as if the file came from an older version.
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var profiles = obj["profiles"] as! [[String: Any]]
        profiles[0].removeValue(forKey: "path")
        var voice = profiles[0]["voice"] as! [String: Any]
        voice.removeValue(forKey: "pitch")
        voice["rate"] = 0.6
        profiles[0]["voice"] = voice
        var rules = profiles[0]["alertRules"] as! [String: Any]
        rules["Made Up Warning"] = ["enabled": true, "priority": 9]
        profiles[0]["alertRules"] = rules
        obj["profiles"] = profiles
        obj.removeValue(forKey: "general")
        let old = try JSONSerialization.data(withJSONObject: obj)
        let imported = try SettingsIO.decode(old)
        XCTAssertEqual(imported.profiles[0].voice.rate, 0.6)
        XCTAssertEqual(imported.profiles[0].voice.pitch, 1.0)
        XCTAssertEqual(imported.profiles[0].path, PathSettings())
        XCTAssertEqual(imported.profiles[0].alertRules["Made Up Warning"]?.priority, 9)
        XCTAssertEqual(imported.profiles[0].alertRules["Made Up Warning"]?.mode, .speak)
        XCTAssertEqual(imported.general, GeneralSettings())
    }

    func testSingleProfileImportAndMerge() throws {
        var p = Profile.quiet
        p.id = "custom"
        p.name = "My Custom"
        let data = try SettingsIO.encode(profile: p)
        let imported = try SettingsIO.decode(data)
        XCTAssertEqual(imported.profiles.count, 1)
        XCTAssertEqual(imported.activeProfile.name, "My Custom")
        let merged = SettingsIO.mergeProfiles(from: imported, into: .defaults)
        XCTAssertEqual(merged.profiles.count, AppSettings.defaults.profiles.count + 1)
    }

    func testBadFileGivesError() {
        XCTAssertThrowsError(try SettingsIO.decode(Data("hello".utf8)))
        XCTAssertThrowsError(try SettingsIO.decode(Data(#"{"profiles":[{"voice":{"rate":"fast"}}]}"#.utf8)))
    }

    func testToneSynth() {
        for t in ToneID.allCases where t != .none {
            let s = ToneSynth.samples(t)
            XCTAssertGreaterThan(s.count, 1000, "\(t)")
            XCTAssertLessThanOrEqual(s.map { abs($0) }.max() ?? 0, 1.0)
        }
        XCTAssertTrue(ToneSynth.samples(.none).isEmpty)
    }
}
