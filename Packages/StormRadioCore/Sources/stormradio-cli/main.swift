import Foundation
import StormRadioCore

// Developer tool for testing the Storm Radio engine on a computer (macOS or Linux).
//
//   stormradio-cli defaults                         print the default settings file
//   stormradio-cli simulate --lat 35.2 --lon -97.4  run the monitor against live data
//        [--radius 150] [--minutes 0] [--settings file.json]
//   stormradio-cli phrase <alerts.geojson> --lat .. --lon ..   compose text for every alert in a saved feed
//   stormradio-cli replay <snap1.json> <snap2.json> ... --lat .. --lon ..   feed snapshots in order (tests updates)

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func loadSettings(_ path: String?) -> AppSettings {
    guard let p = path else { return AppSettings.defaults }
    do { return try SettingsIO.decode(try Data(contentsOf: URL(fileURLWithPath: p))) } catch {
        FileHandle.standardError.write("Could not read settings: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

func printAnnouncements(_ list: [Announcement]) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    for a in list {
        print("[\(f.string(from: a.date))] (\(a.category.rawValue), p\(a.priority), \(a.mode.rawValue)\(a.tone == .none ? "" : "+\(a.tone.rawValue)")) \(a.title)")
        print("    \u{1F50A} \(a.spokenText)")
    }
}

let command = args.first ?? "help"
args = Array(args.dropFirst())

switch command {
case "defaults":
    let data = try SettingsIO.encode(AppSettings.defaults)
    print(String(decoding: data, as: UTF8.self))

case "simulate":
    let lat = Double(option("--lat") ?? "") ?? 35.22
    let lon = Double(option("--lon") ?? "") ?? -97.44
    let radius = option("--radius").flatMap(Double.init)
    let minutes = Int(option("--minutes") ?? "0") ?? 0
    var settings = loadSettings(option("--settings"))
    var p = settings.activeProfile
    p.location.mode = .fixed
    p.location.fixedPoint = GeoPoint(lat: lat, lon: lon)
    if let r = radius {
        p.location.radiusMiles = r
        for k in p.alertRules.keys { p.alertRules[k]?.maxDistanceMiles = r }
        p.reports.maxDistanceMiles = r
    }
    settings.activeProfile = p
    let monitor = StormMonitor(settings: settings)
    print("Monitoring \(lat), \(lon) with profile '\(p.name)', radius \(p.location.radiusMiles) mi")
    let end = Date().addingTimeInterval(Double(minutes) * 60)
    var first = true
    repeat {
        var out: [Announcement] = []
        out += await monitor.pollAlerts()
        out += await monitor.pollReports()
        if first {
            out += await monitor.pollSPC()
            out += await monitor.pollAFD()
        }
        printAnnouncements(out)
        if first {
            print("\n--- Active alerts tracked: \(await monitor.activeEventCount)")
            for info in await monitor.activeAlertInfos().prefix(15) {
                print("  \(info.inRange ? "*" : " ") \(info.title)  risk \(info.risk)\(info.path.map { " IN PATH eta \(Int($0.etaMinutes ?? 0))m" } ?? "")")
            }
            print("\n--- Sources")
            for (k, s) in await monitor.status.sorted(by: { $0.key < $1.key }) {
                print("  \(k): \(s.ok ? "ok" : "ERROR \(s.lastError ?? "")") (\(s.itemCount))")
            }
            print("\n--- On-demand buttons")
            let buttons = [await monitor.nearbySummary(), await monitor.mdAnnouncement(), await monitor.outlookAnnouncement(day: 1),
                           await monitor.afdAnnouncement(), await monitor.reportsSummary()]
            printAnnouncements(buttons)
            first = false
        }
        if Date() < end { try await Task.sleep(nanoseconds: UInt64(settings.general.alertPollSeconds) * 1_000_000_000) }
    } while Date() < end

case "phrase":
    guard let file = args.first else { print("usage: phrase <alerts.json> --lat --lon"); exit(1) }
    let lat = Double(option("--lat") ?? "")
    let lon = Double(option("--lon") ?? "")
    let settings = loadSettings(option("--settings"))
    let ref = lat.flatMap { la in lon.map { GeoPoint(lat: la, lon: $0) } }
    let alerts = try NWSAlertParser.parseCollection(try Data(contentsOf: URL(fileURLWithPath: file)))
    let ph = AlertPhraser(options: settings.activeProfile.phrasing, template: settings.activeProfile.template)
    for a in alerts {
        let now = a.sent ?? Date()
        let r = ref ?? a.geometry.flatMap(Geo.centroid).map { Geo.destination(from: $0, bearingDegrees: 225, miles: 6) }
        let ctx = AlertContext(reference: r, now: now.addingTimeInterval(120), verb: a.primaryVTEC?.action == .new ? .issued : .updated)
        print("\(a.event) [\(a.primaryVTEC?.action.rawValue ?? "-")] \(a.id.suffix(12))")
        print("    \u{1F50A} \(ph.compose(a, ctx))\n")
    }

case "replay":
    let lat = Double(option("--lat") ?? "") ?? 35.22
    let lon = Double(option("--lon") ?? "") ?? -97.44
    var settings = loadSettings(option("--settings"))
    var p = settings.activeProfile
    p.location.mode = .fixed
    p.location.fixedPoint = GeoPoint(lat: lat, lon: lon)
    settings.activeProfile = p
    let monitor = StormMonitor(settings: settings)
    for file in args {
        let alerts = try NWSAlertParser.parseCollection(try Data(contentsOf: URL(fileURLWithPath: file)))
        let now = alerts.compactMap { $0.sent }.max() ?? Date()
        print("== \(file) (\(alerts.count) alerts)")
        printAnnouncements(await monitor.process(alerts: alerts, now: now.addingTimeInterval(60)))
    }

default:
    print("""
    stormradio-cli commands:
      defaults                                  print default settings JSON
      simulate --lat 35.2 --lon -97.4 [--radius 150] [--minutes 10] [--settings f.json]
      phrase <alerts.json> [--lat --lon]        compose text for each alert in a saved NWS feed
      replay <snap1.json> <snap2.json> ...      feed saved snapshots in order
    """)
}
