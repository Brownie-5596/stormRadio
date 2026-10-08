import XCTest
@testable import StormRadioCore

final class TrackingTests: XCTestCase {
    func testRealSequenceNewPartialCancelExpire() throws {
        let tracker = AlertTracker()
        let t0 = date("2026-10-08T01:30:00Z")
        XCTAssertTrue(tracker.ingest([], now: t0).isEmpty) // first poll: nothing active

        let s1 = try Fixture.alerts("buf_1_new.json")
        let l1 = tracker.ingest(s1, now: t0.addingTimeInterval(600))
        XCTAssertEqual(l1.count, 1)
        guard case .issued(let key) = l1[0] else { return XCTFail("expected issued, got \(l1)") }
        XCTAssertEqual(key, "KBUF.SV.W.0116")
        XCTAssertTrue(tracker.event(key)!.seenAsNew)

        let s2 = try Fixture.alerts("buf_2_partial.json")
        let l2 = tracker.ingest(s2, now: t0.addingTimeInterval(1800))
        XCTAssertEqual(l2.count, 1)
        guard case .partiallyCancelled(_, let cancel, _, _) = l2[0] else { return XCTFail("expected partial cancel, got \(l2)") }
        XCTAssertTrue(cancel.nwsHeadline?.contains("CANCELLED") ?? false)

        let s3 = try Fixture.alerts("buf_3_exp.json")
        let l3 = tracker.ingest(s3, now: t0.addingTimeInterval(3400))
        XCTAssertEqual(l3.count, 1)
        guard case .expired = l3[0] else { return XCTFail("expected expired, got \(l3)") }
        XCTAssertTrue(tracker.event(key)!.ended)
    }

    func testDiffDetectsEscalation() {
        let now = date("2026-05-06T23:40:00Z")
        var old = makeAlert(sent: now)
        old.maxHailInches = 1.0
        old.hailBasis = .radarIndicated
        old.maxWindMPH = 60
        old.tornadoDetection = .possible
        var new = old
        new.maxHailInches = 2.0
        new.hailBasis = .observed
        new.tornadoDetection = .radarIndicated
        new.thunderstormDamage = .destructive
        new.ends = now.addingTimeInterval(80 * 60)
        new.vtec[0].end = new.ends
        let changes = AlertTracker.diff(old, new)
        XCTAssertTrue(changes.contains(.hail(from: 1.0, to: 2.0, basis: .observed)))
        XCTAssertTrue(changes.contains(.tornado(from: .possible, to: .radarIndicated)))
        XCTAssertTrue(changes.contains(.damage(from: .none, to: .destructive)))
        XCTAssertTrue(changes.contains { if case .extended = $0 { return true }; return false })
        XCTAssertTrue(changes.contains { $0.isEscalation })

        let ph = AlertPhraser(options: PhraseOptions(), template: .standard)
        let ctx = AlertContext(reference: GeoPoint(lat: 35.2, lon: -97.5), now: now, timeZone: TimeZone(identifier: "UTC")!, verb: .updated)
        let text = ph.updateText(new, changes: changes, ctx)
        XCTAssertTrue(text.hasPrefix("Update on the severe thunderstorm warning 6 miles east."), text)
        XCTAssertTrue(text.contains("Hail increased to 2 inch, hen egg size, observed."), text)
        XCTAssertTrue(text.contains("A tornado is now indicated by radar."), text)
        XCTAssertTrue(text.contains("The damage threat was raised to destructive."), text)
        XCTAssertTrue(text.contains("It has been extended until 1:00."), text)
    }

    func testAreaReduction() {
        let now = date("2026-05-06T23:40:00Z")
        let old = makeAlert(sent: now)
        var new = old
        new.geometry = GeoShape(ring: [
            GeoPoint(lat: 35.30, lon: -97.30), GeoPoint(lat: 35.30, lon: -97.20),
            GeoPoint(lat: 35.10, lon: -97.20), GeoPoint(lat: 35.10, lon: -97.30),
        ])
        let changes = AlertTracker.diff(old, new)
        XCTAssertTrue(changes.contains { if case .areaReduced(let p) = $0 { return p >= 45 && p <= 55 }; return false }, "\(changes)")
    }

    func testVanishedBeforeEndIsEnded() {
        let tracker = AlertTracker()
        let now = date("2026-05-06T23:40:00Z")
        _ = tracker.ingest([], now: now)
        let a = makeAlert(sent: now, minutes: 60)
        _ = tracker.ingest([a], now: now.addingTimeInterval(30))
        XCTAssertTrue(tracker.ingest([], now: now.addingTimeInterval(60)).isEmpty) // one missed poll is tolerated
        let l = tracker.ingest([], now: now.addingTimeInterval(90))
        guard case .ended = l.first else { return XCTFail("\(l)") }
    }

    func testPathETA() {
        let now = date("2026-05-06T23:40:00Z")
        let user = GeoPoint(lat: 35.2, lon: -97.4)
        let stormPos = Geo.destination(from: user, bearingDegrees: 270, miles: 20)
        // Storm coming from the west (270) at 26 kt (~30 mph): ~40 minutes away.
        let m = StormMotion(time: now, fromDegrees: 270, speedKnots: 26.07, points: [stormPos])
        let r = StormPath.evaluate(motion: m, point: user, now: now, halfWidthMiles: 4)
        XCTAssertTrue(r.inPath)
        XCTAssertEqual(r.etaMinutes ?? 0, 40, accuracy: 1.5)
        let off = Geo.destination(from: user, bearingDegrees: 0, miles: 10)
        XCTAssertFalse(StormPath.evaluate(motion: m, point: off, now: now, halfWidthMiles: 4).inPath)
        let behind = Geo.destination(from: user, bearingDegrees: 270, miles: 30)
        XCTAssertFalse(StormPath.evaluate(motion: m, point: behind, now: now, halfWidthMiles: 4).inPath)
    }

    func testLineOfStormsPath() {
        let now = date("2026-05-06T23:40:00Z")
        let user = GeoPoint(lat: 35.2, lon: -97.4)
        // A north-south line 15 miles west, 30 miles long, moving east. User is in line with its northern half.
        let center = Geo.destination(from: user, bearingDegrees: 270, miles: 15)
        let north = Geo.destination(from: center, bearingDegrees: 0, miles: 15)
        let south = Geo.destination(from: center, bearingDegrees: 180, miles: 15)
        let m = StormMotion(time: now, fromDegrees: 270, speedKnots: 39, points: [north, south])
        let r = StormPath.evaluate(motion: m, point: Geo.destination(from: user, bearingDegrees: 0, miles: 8), now: now, halfWidthMiles: 3)
        XCTAssertTrue(r.inPath)
        XCTAssertEqual(r.etaMinutes ?? 0, 20, accuracy: 2)
    }

    func testGeo() {
        let okc = GeoPoint(lat: 35.4676, lon: -97.5164)
        let tul = GeoPoint(lat: 36.154, lon: -95.9928)
        XCTAssertEqual(Geo.distanceMiles(okc, tul), 98.5, accuracy: 2)
        XCTAssertEqual(Geo.bearing(from: okc, to: tul), 61, accuracy: 3)
        let box = GeoShape(ring: [GeoPoint(lat: 35, lon: -98), GeoPoint(lat: 36, lon: -98), GeoPoint(lat: 36, lon: -97), GeoPoint(lat: 35, lon: -97)])
        XCTAssertTrue(Geo.contains(box, GeoPoint(lat: 35.5, lon: -97.5)))
        XCTAssertFalse(Geo.contains(box, GeoPoint(lat: 34.9, lon: -97.5)))
        let d = Geo.distance(from: GeoPoint(lat: 34.9, lon: -97.5), to: box)!
        XCTAssertEqual(d.miles, 6.9, accuracy: 0.3)
        XCTAssertEqual(Geo.areaSquareMiles(box), 69 * 69 * 0.82, accuracy: 300)
    }
}
