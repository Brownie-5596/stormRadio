import Foundation
import XCTest
@testable import StormRadioCore

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }
    static func alerts(_ name: String) throws -> [WeatherAlert] { try NWSAlertParser.parseCollection(try data(name)) }
}

/// Builds a synthetic alert for phrase/diff tests.
func makeAlert(event: String = "Severe Thunderstorm Warning", action: VTECAction = .new, etn: Int = 42,
               polygon: [GeoPoint]? = nil, sent: Date, minutes: Double = 50) -> WeatherAlert {
    var a = WeatherAlert(id: "test-\(UUID().uuidString)", event: event)
    let end = sent.addingTimeInterval(minutes * 60)
    let phen = event.hasPrefix("Tornado") ? "TO" : "SV"
    a.vtec = [VTEC(productClass: "O", action: action, office: "KOUN", phenomena: phen, significance: "W", eventNumber: etn,
                   begin: action == .new ? sent : nil, end: end)]
    a.sent = sent
    a.effective = sent
    a.expires = end
    a.ends = end
    a.senderName = "NWS Norman OK"
    a.areaDesc = "Cleveland, OK; McClain, OK"
    a.ugc = ["OKC027", "OKC087"]
    a.geometry = GeoShape(ring: polygon ?? [
        GeoPoint(lat: 35.30, lon: -97.40), GeoPoint(lat: 35.30, lon: -97.20),
        GeoPoint(lat: 35.10, lon: -97.20), GeoPoint(lat: 35.10, lon: -97.40),
    ])
    return a
}

func date(_ iso: String) -> Date { WxDate.iso(iso)! }
