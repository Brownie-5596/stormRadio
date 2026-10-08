import XCTest
@testable import StormRadioCore

final class PhraseTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    /// The example from the original request:
    /// "A considerable severe thunderstorm warning was issued 6 miles to the north east. 60mph wind gusts were indicated by radar
    ///  and 2 inch or egg sized hail was observed by NWS employee. It expires in 50 minutes at 7:30."
    func testUserExample() {
        let issued = date("2026-05-06T23:40:00Z")
        var a = makeAlert(sent: issued, minutes: 50)
        a.thunderstormDamage = .considerable
        a.maxWindMPH = 60
        a.windBasis = .radarIndicated
        a.maxHailInches = 2.0
        a.hailBasis = .observed
        a.description = "At 640 PM CDT, a severe thunderstorm was located...\n\nHAZARD...60 mph wind gusts and hen egg size hail.\n\nSOURCE...NWS employee.\n\nIMPACT...Damage."
        // Put the user 6 miles southwest of the polygon's southwest corner.
        let corner = GeoPoint(lat: 35.10, lon: -97.40)
        let user = Geo.destination(from: corner, bearingDegrees: 225, miles: 6)
        var ph = AlertPhraser(options: PhraseOptions(), template: .standard)
        ph.options.sayAMPM = false
        let ctx = AlertContext(reference: user, now: issued.addingTimeInterval(30), timeZone: utc, verb: .issued)
        let text = ph.compose(a, ctx)
        XCTAssertEqual(text, "A considerable severe thunderstorm warning was issued 6 miles to the northeast. 60 mile per hour wind gusts were indicated by radar and 2 inch, hen egg size hail was observed by N W S employee. It expires in 50 minutes, at 12:30.")
    }

    func testPDSAndEmergency() {
        let now = date("2026-05-06T23:40:00Z")
        var a = makeAlert(event: "Tornado Warning", sent: now)
        a.tornadoDetection = .observed
        a.tornadoDamage = .catastrophic
        a.description = "TORNADO EMERGENCY FOR MOORE\n\nSOURCE...Emergency management reported a large tornado.\n\n"
        let ph = AlertPhraser(options: PhraseOptions(), template: .standard)
        let ctx = AlertContext(reference: GeoPoint(lat: 35.2, lon: -97.3), now: now, timeZone: utc)
        let text = ph.compose(a, ctx)
        XCTAssertTrue(text.hasPrefix("Tornado emergency! A tornado warning was issued for your location."), text)
        XCTAssertTrue(text.contains("A tornado was observed."), text)
        XCTAssertTrue(text.contains("Source: emergency management reported a large tornado."), text)
    }

    func testCustomFormat() {
        let now = date("2026-05-06T23:40:00Z")
        var a = makeAlert(sent: now, minutes: 30)
        a.maxHailInches = 1.75
        a.hailBasis = .radarIndicated
        var t = MessageTemplate.standard
        t.useCustomFormat = true
        t.customFormat = "{event}, {distance}. {threats}. {unknown} Ends {expiresIn} from now."
        let ph = AlertPhraser(options: PhraseOptions(), template: t)
        let ctx = AlertContext(reference: GeoPoint(lat: 35.2, lon: -97.3), now: now, timeZone: utc)
        XCTAssertEqual(ph.compose(a, ctx), "Severe thunderstorm warning, for your location. 1 and three quarter inch, golf ball size hail was indicated by radar. Ends 30 minutes from now.")
    }

    func testBlockReorderAndDisable() {
        let now = date("2026-05-06T23:40:00Z")
        var a = makeAlert(sent: now, minutes: 30)
        a.maxWindMPH = 70
        a.windBasis = .observed
        var t = MessageTemplate.standard
        // Expiration first, then the header; threats off.
        t.blocks = [TemplateBlock(.expires), TemplateBlock(.event), TemplateBlock(.distance), TemplateBlock(.threats, false)]
        t.normalize()
        XCTAssertEqual(t.blocks.count, PhraseBlockKind.allCases.count)
        let ph = AlertPhraser(options: PhraseOptions(), template: t)
        let ctx = AlertContext(reference: GeoPoint(lat: 35.2, lon: -97.3), now: now, timeZone: utc)
        XCTAssertEqual(ph.compose(a, ctx), "It expires in 30 minutes, at 12:10. A severe thunderstorm warning was issued for your location.")
    }

    func testSpokenHelpers() {
        XCTAssertEqual(Spoken.inches(1.75), "1 and three quarter inch")
        XCTAssertEqual(Spoken.inches(0.75), "three quarter inch")
        XCTAssertEqual(Spoken.inches(2.0), "2 inch")
        XCTAssertEqual(Spoken.hail(2.75, style: .inchesAndObject), "2 and three quarter inch, baseball size hail")
        XCTAssertEqual(Spoken.duration(minutes: 80), "1 hour and 20 minutes")
        XCTAssertEqual(Spoken.distance(0.4), "less than a mile")
        XCTAssertEqual(Spoken.lsrPlace("2 ENE Mcintyre"), "2 miles east-northeast of Mcintyre")
        XCTAssertEqual(Spoken.list(["a", "b", "c"]), "a, b, and c")
        XCTAssertEqual(Spoken.tidy(" , A  storm . . is near ,."), "A storm. Is near.")
    }

    func testCompass() {
        XCTAssertEqual(Compass.name(for: 44, style: .eight), "northeast")
        XCTAssertEqual(Compass.name(for: 350, style: .eight), "north")
        XCTAssertEqual(Compass.name(for: 67.5, style: .sixteen), "east-northeast")
        XCTAssertEqual(Compass.abbreviation(for: 225), "SW")
    }

    func testReportPhrase() {
        let now = date("2026-05-06T23:40:00Z")
        let r = StormReport(id: "1", source: .nwsLSR, category: .hail, typeText: "hail", magnitude: 1.75, unit: "Inch", reporter: "Trained Spotter",
                            place: "3 SW Moore", point: GeoPoint(lat: 35.30, lon: -97.50), eventTime: now.addingTimeInterval(-40 * 60),
                            releasedTime: now.addingTimeInterval(-2 * 60))
        var s = ReportSettings()
        s.saySource = false
        let ph = ReportPhraser(settings: s, phrasing: PhraseOptions())
        let text = ph.compose(r, from: GeoPoint(lat: 35.2, lon: -97.5), now: now, timeZone: utc)
        XCTAssertEqual(text, "1 and three quarter inch, golf ball size hail, reported by a trained spotter, 7 miles to the north, 3 miles southwest of Moore. Delayed report. It happened at 11:00, 40 minutes ago.")
    }
}
