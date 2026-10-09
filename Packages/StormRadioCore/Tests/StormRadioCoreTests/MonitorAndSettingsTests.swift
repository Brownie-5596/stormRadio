import XCTest
@testable import StormRadioCore

final class MonitorAndSettingsTests: XCTestCase {
    func monitor(at p: GeoPoint, mode: LocationMode = .fixed) async -> StormMonitor {
        var s = AppSettings.defaults
        var prof = s.activeProfile
        prof.location.mode = mode
        prof.location.fixedPoint = mode == .fixed ? p : nil
        prof.startupSummary = false
        s.activeProfile = prof
        let m = StormMonitor(settings: s)
        await m.setTimeZone(TimeZone(identifier: "UTC")!)
        if mode == .gps { _ = await m.updateLocation(p, now: Date()) }
        return m
    }

    func testIssueUpdateCancelFlow() async {
        let now = date("2026-05-06T23:40:00Z")
        let m = await monitor(at: GeoPoint(lat: 35.2, lon: -97.5)) // ~6 miles west of the test polygon
        let initial = await m.process(alerts: [], now: now)
        XCTAssertTrue(initial.isEmpty)

        var a = makeAlert(sent: now)
        a.maxWindMPH = 60
        a.windBasis = .radarIndicated
        let issued = await m.process(alerts: [a], now: now.addingTimeInterval(20))
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
        let upd = await m.process(alerts: [u], now: now.addingTimeInterval(620))
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
        let can = await m.process(alerts: [c], now: now.addingTimeInterval(1220))
        XCTAssertEqual(can.count, 1)
        XCTAssertEqual(can[0].spokenText, "The severe thunderstorm warning 6 miles east has been cancelled. The storm which prompted the warning has weakened below severe limits, and no longer poses an immediate threat to life or property.")
        XCTAssertFalse(can[0].canInterrupt)
    }

    func testOutOfRangeIsSilentButTracked() async {
        let now = date("2026-05-06T23:40:00Z")
        let m = await monitor(at: GeoPoint(lat: 36.5, lon: -97.3)) // ~85 miles north
        _ = await m.process(alerts: [], now: now)
        let out = await m.process(alerts: [makeAlert(sent: now)], now: now.addingTimeInterval(10))
        XCTAssertTrue(out.isEmpty)
        let count = await m.activeEventCount
        XCTAssertEqual(count, 1)
        let infos = await m.activeAlertInfos(now: now)
        XCTAssertFalse(infos.first!.inRange)
    }

    func testEnteredAndLeftWarningWithGPS() async {
        let now = date("2026-05-06T23:40:00Z")
        let m = await monitor(at: GeoPoint(lat: 35.2, lon: -97.6), mode: .gps)
        _ = await m.process(alerts: [], now: now)
        _ = await m.process(alerts: [makeAlert(sent: now)], now: now.addingTimeInterval(10))
        let entered = await m.updateLocation(GeoPoint(lat: 35.2, lon: -97.3), now: now.addingTimeInterval(300))
        XCTAssertEqual(entered.count, 1)
        XCTAssertEqual(entered[0].category, .location)
        XCTAssertTrue(entered[0].spokenText.hasPrefix("You have entered a severe thunderstorm warning."), entered[0].spokenText)
        let still = await m.updateLocation(GeoPoint(lat: 35.21, lon: -97.31), now: now.addingTimeInterval(320))
        XCTAssertTrue(still.isEmpty)
        let left = await m.updateLocation(GeoPoint(lat: 35.2, lon: -97.1), now: now.addingTimeInterval(900))
        XCTAssertEqual(left.first?.spokenText, "You have left the severe thunderstorm warning.")
    }

    func testPathAlertFiresOncePerThreshold() async {
        let now = date("2026-05-06T23:40:00Z")
        let user = GeoPoint(lat: 35.2, lon: -97.0) // east of the polygon
        let m = await monitor(at: user)
        _ = await m.process(alerts: [], now: now)
        var a = makeAlert(event: "Tornado Warning", sent: now)
        a.tornadoDetection = .radarIndicated
        let stormPos = Geo.destination(from: user, bearingDegrees: 270, miles: 18)
        a.motion = StormMotion(time: now, fromDegrees: 270, speedKnots: 39, points: [stormPos]) // 45 mph -> 24 min
        let first = await m.process(alerts: [a], now: now.addingTimeInterval(5))
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].spokenText.contains("You are in the path"), first[0].spokenText)
        // Same poll again a minute later: the 30-minute threshold already fired with the issuance.
        let again = await m.process(alerts: [a], now: now.addingTimeInterval(65))
        XCTAssertTrue(again.filter { $0.category == .path }.isEmpty)
        // 10 minutes later (ETA ~14 min) the 15-minute threshold fires.
        let later = await m.process(alerts: [a], now: now.addingTimeInterval(600))
        XCTAssertEqual(later.filter { $0.category == .path }.count, 1, "\(later.map { $0.spokenText })")
    }

    /// Driving into a storm's path when it's already under 5 minutes away still gives one alert with the real ETA.
    func testEnteringPathWithUnderFiveMinutes() async {
        let now = date("2026-05-06T23:40:00Z")
        var s = AppSettings.defaults
        var prof = s.activeProfile
        prof.location.mode = .gps
        prof.startupSummary = false
        s.activeProfile = prof
        let m = StormMonitor(settings: s)
        await m.setTimeZone(TimeZone(identifier: "UTC")!)
        // Start well off to the side of the track.
        let track = GeoPoint(lat: 35.2, lon: -97.0)
        _ = await m.updateLocation(Geo.destination(from: track, bearingDegrees: 0, miles: 15), now: now)
        _ = await m.process(alerts: [], now: now)
        var a = makeAlert(event: "Tornado Warning", sent: now, minutes: 45)
        a.tornadoDetection = .radarIndicated
        // Storm 3 miles west of the track point, moving east at 45 mph -> ~4 minutes out.
        a.motion = StormMotion(time: now, fromDegrees: 270, speedKnots: 39, points: [Geo.destination(from: track, bearingDegrees: 270, miles: 3)])
        let issued = await m.process(alerts: [a], now: now.addingTimeInterval(1))
        XCTAssertTrue(issued.filter { $0.category == .path }.isEmpty, "not in the path yet")
        // Drive onto the track.
        let entered = await m.updateLocation(track, now: now.addingTimeInterval(2))
        let path = entered.filter { $0.category == .path }
        XCTAssertEqual(path.count, 1, "\(entered.map { $0.spokenText })")
        XCTAssertTrue(path.first?.spokenText.contains("Arrival in about 4 minutes") ?? false, path.first?.spokenText ?? "")
        // No repeat a few seconds later.
        let again = await m.updateLocation(GeoPoint(lat: 35.2005, lon: -97.0), now: now.addingTimeInterval(20))
        XCTAssertTrue(again.filter { $0.category == .path }.isEmpty)
    }

    func testFirstGPSFixGivesSummaryNotABurst() async {
        let now = date("2026-05-06T23:40:00Z")
        var s = AppSettings.defaults
        var prof = s.activeProfile
        prof.location.mode = .gps
        s.activeProfile = prof
        let m = StormMonitor(settings: s)
        let first = await m.process(alerts: [makeAlert(sent: now), makeAlert(event: "Tornado Warning", etn: 7, sent: now)], now: now)
        XCTAssertEqual(first.count, 1) // "waiting for a location" summary
        let fix = await m.updateLocation(GeoPoint(lat: 35.2, lon: -97.5), now: now.addingTimeInterval(30))
        XCTAssertEqual(fix.count, 1)
        XCTAssertEqual(fix.first?.category, .summary)
        XCTAssertTrue(fix.first?.spokenText.contains("Active in range") ?? false, fix.first?.spokenText ?? "")
        let next = await m.updateLocation(GeoPoint(lat: 35.21, lon: -97.5), now: now.addingTimeInterval(60))
        XCTAssertTrue(next.isEmpty)
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

    func testCustomToneRoundTrip() throws {
        var s = AppSettings.defaults
        s.profiles[0].alertRules["Tornado Warning"]?.tone = .custom("My Siren.m4a")
        let back = try SettingsIO.decode(try SettingsIO.encode(s))
        let tone = back.profiles[0].alertRules["Tornado Warning"]?.tone
        XCTAssertEqual(tone, .custom("My Siren.m4a"))
        XCTAssertEqual(tone?.isCustom, true)
        XCTAssertEqual(tone?.label, "My Siren")
        XCTAssertTrue(String(decoding: try SettingsIO.encode(s), as: UTF8.self).contains(#""tone" : "custom:My Siren.m4a""#))
    }

    func testSPCImageLinks() throws {
        let md = try XCTUnwrap(MesoscaleDiscussion.parse(try Fixture.text("mcd.txt"), id: "x", issued: date("2026-10-06T19:04:00Z")))
        XCTAssertEqual(md.imageURL?.absoluteString, "https://www.spc.noaa.gov/products/md/2026/mcd2346.png")
        XCTAssertEqual(md.link?.absoluteString, "https://www.spc.noaa.gov/products/md/2026/md2346.html")
        let o = OutlookSummary.parse(try Fixture.text("swody1.txt"), day: 1, id: "x", issued: Date())
        XCTAssertEqual(o.imageLinks.count, 4)
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
