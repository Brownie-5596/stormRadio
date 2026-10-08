import XCTest
@testable import StormRadioCore

final class ParsingTests: XCTestCase {
    func testVTEC() {
        let v = VTEC.parse("/O.NEW.KJAX.SV.W.0261.261003T2339Z-261004T0015Z/")!
        XCTAssertEqual(v.action, .new)
        XCTAssertEqual(v.office, "KJAX")
        XCTAssertEqual(v.phenomena, "SV")
        XCTAssertEqual(v.significance, "W")
        XCTAssertEqual(v.eventNumber, 261)
        XCTAssertEqual(v.eventKey, "KJAX.SV.W.0261")
        XCTAssertEqual(v.begin, date("2026-10-03T23:39:00Z"))
        XCTAssertEqual(v.end, date("2026-10-04T00:15:00Z"))
        let c = VTEC.parse("/O.CON.KBUF.SV.W.0116.000000T0000Z-261008T0230Z/")!
        XCTAssertNil(c.begin)
        XCTAssertEqual(c.action, .con)
    }

    func testDates() {
        XCTAssertNotNil(WxDate.iso("2026-10-08T18:53:00-04:00"))
        XCTAssertEqual(WxDate.iso("2026-10-04T21:20:00-00:00"), date("2026-10-04T21:20:00Z"))
        XCTAssertEqual(WxDate.compact("202610082118-KAPX-NWUS53-LSRAPX"), date("2026-10-08T21:18:00Z"))
        XCTAssertEqual(WxDate.spaced("2026-10-08 22:18:11 UTC"), date("2026-10-08T22:18:11Z"))
    }

    func testSevereWarningParsing() throws {
        let a = try XCTUnwrap(Fixture.alerts("buf_1_new.json").first)
        XCTAssertEqual(a.event, "Severe Thunderstorm Warning")
        XCTAssertEqual(a.maxHailInches, 1.0)
        XCTAssertEqual(a.hailBasis, .radarIndicated)
        XCTAssertEqual(a.maxWindMPH, 60)
        XCTAssertEqual(a.windBasis, .radarIndicated)
        XCTAssertEqual(a.primaryVTEC?.action, .new)
        XCTAssertNotNil(a.geometry)
        let m = try XCTUnwrap(a.motion)
        XCTAssertEqual(m.fromDegrees, 266)
        XCTAssertEqual(m.speedKnots, 39)
        XCTAssertEqual(m.headingDegrees, 86)
        XCTAssertEqual(a.sourceText, "Radar indicated")
        XCTAssertFalse(a.locationsImpacted.isEmpty)
        XCTAssertEqual(a.webLink?.host, "mesonet.agron.iastate.edu")
    }

    func testTornadoWarningParsing() throws {
        let alerts = try Fixture.alerts("tor.json")
        let new = try XCTUnwrap(alerts.first { $0.primaryVTEC?.action == .new })
        XCTAssertEqual(new.tornadoDetection, .radarIndicated)
        XCTAssertNil(new.maxHailInches) // "0.00" means none
        XCTAssertEqual(new.sourceText, "Radar indicated rotation")
        XCTAssertEqual(RiskIndex.score(new), 4)
    }

    func testHailAndWindValueParsing() {
        XCTAssertEqual(NWSAlertParser.parseHail("Up to .75"), 0.75)
        XCTAssertEqual(NWSAlertParser.parseHail("2.00"), 2.0)
        XCTAssertNil(NWSAlertParser.parseHail("0.00"))
        XCTAssertEqual(NWSAlertParser.parseWind("60 MPH"), 60)
        XCTAssertEqual(NWSAlertParser.parseWind("50 KT"), 58)
    }

    func testMesoscaleDiscussion() throws {
        let md = try XCTUnwrap(MesoscaleDiscussion.parse(try Fixture.text("mcd.txt"), id: "x", issued: Date()))
        XCTAssertEqual(md.number, 2346)
        XCTAssertEqual(md.areasAffected, "west-central Florida Peninsula")
        XCTAssertEqual(md.watchProbability, 5)
        XCTAssertEqual(md.polygon.count, 13)
        XCTAssertEqual(md.polygon.first, GeoPoint(lat: 28.12, lon: -83.31))
        XCTAssertTrue(md.summary.hasPrefix("The risk for a brief tornado"))
        XCTAssertEqual(md.peakTornado, "UP TO 90 MPH")
        let text = md.announcement(from: GeoPoint(lat: 27.95, lon: -82.46), compass: .eight, readSummary: false)
        XCTAssertTrue(text.contains("Mesoscale Discussion 2346"), text)
        XCTAssertTrue(text.contains("watch unlikely"), text)
    }

    func testOutlookText() throws {
        let o = OutlookSummary.parse(try Fixture.text("swody1.txt"), day: 1, id: "x", issued: Date())
        XCTAssertEqual(o.maxCategory, .mrgl)
        XCTAssertFalse(o.headlines.isEmpty)
        XCTAssertFalse(o.summary.isEmpty)
    }

    func testOutlookLayer() throws {
        let layer = try OutlookLayer.parse(try Fixture.data("day1_cat.geojson"))
        XCTAssertFalse(layer.areas.isEmpty)
        XCTAssertGreaterThanOrEqual(layer.maxCategory, .tstm)
        XCTAssertEqual(layer.category(at: GeoPoint(lat: 47.6, lon: -122.3)), .none) // Seattle: nothing
    }

    func testAFDSections() throws {
        let afd = AreaForecastDiscussion.parse(try Fixture.text("afd_oun.txt"), office: "OUN", id: "x", issued: Date())
        let names = afd.sections.map { $0.name }
        XCTAssertTrue(names.contains("KEY MESSAGES"), "\(names)")
        XCTAssertTrue(names.contains("SHORT TERM"), "\(names)")
        let km = afd.text(for: ["KEY MESSAGES"])
        XCTAssertEqual(km.count, 1)
        XCTAssertFalse(km[0].1.contains("Updated at"))
        XCTAssertEqual(StormMonitor.officeName(from: try Fixture.text("afd_oun.txt")), "Norman")
    }

    func testSpotterNetwork() throws {
        let r = ReportParsers.parseSpotterNetwork(try Fixture.text("spotternetwork.txt"))
        XCTAssertEqual(r.count, 3)
        let hail = try XCTUnwrap(r.first { $0.category == .hail })
        XCTAssertEqual(hail.magnitude, 1.75)
        XCTAssertEqual(hail.reporter, "Jane Chaser")
        XCTAssertEqual(r.first { $0.category == .tornado }?.eventTime, date("2026-10-08T22:35:00Z"))
        XCTAssertEqual(r.first?.category, .flashFlood)
    }

    func testLSR() throws {
        let r = try ReportParsers.parseLSR(try Fixture.data("lsr.json"))
        XCTAssertEqual(r.count, 12)
        let hail = try XCTUnwrap(r.first { $0.category == .hail })
        XCTAssertNotNil(hail.releasedTime)
        XCTAssertEqual(hail.source, .nwsLSR)
    }

    func testMPing() throws {
        let json = """
        {"count":1,"next":null,"results":[{"id":123,"obtime":"2026-10-08T22:00:00Z","category":"Hail","description":"Golf Ball (1.75 in.)","description_id":9,"geom":{"type":"Point","coordinates":[-97.5,35.2]}}]}
        """
        let r = try ReportParsers.parseMPing(Data(json.utf8))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].magnitude, 1.75)
        XCTAssertEqual(r[0].category, .hail)
        XCTAssertEqual(r[0].point, GeoPoint(lat: 35.2, lon: -97.5))
    }

    func testSPCWatch() {
        let text = """
        WWUS20 KWNS 061826
        SEL0

        URGENT - IMMEDIATE BROADCAST REQUESTED
        Tornado Watch Number 123
        NWS Storm Prediction Center Norman OK
        125 PM CDT Mon May 6 2026

        The NWS Storm Prediction Center has issued a

        * Tornado Watch for portions of
          Central and Northern Oklahoma
          Southern Kansas

        * Effective this Monday afternoon and evening from 125 PM until
          900 PM CDT.

        ...THIS IS A PARTICULARLY DANGEROUS SITUATION...

        * Primary threats include...
          Several tornadoes and a few intense tornadoes likely
          Widespread large hail and isolated very large hail events to 4
            inches in diameter likely

        SUMMARY...Supercells expected.
        """
        let w = SPCWatch.parse(text, id: "x", issued: Date())!
        XCTAssertEqual(w.number, 123)
        XCTAssertEqual(w.type, "Tornado Watch")
        XCTAssertTrue(w.isPDS)
        XCTAssertEqual(w.areas, ["Central and Northern Oklahoma", "Southern Kansas"])
        XCTAssertEqual(w.threats.count, 2)
        XCTAssertTrue(w.threats[1].hasSuffix("4 inches in diameter likely"), w.threats[1])
        let s = w.announcement(readThreats: true)
        XCTAssertTrue(s.hasPrefix("Particularly dangerous situation. S P C issued tornado watch 123"), s)
    }
}
