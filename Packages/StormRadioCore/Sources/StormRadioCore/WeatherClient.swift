import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

public struct HTTPError: LocalizedError {
    public var status: Int
    public var url: URL
    public var errorDescription: String? { "HTTP \(status) from \(url.host ?? url.absoluteString)" }
}

/// URLSession-based fetcher (works on iOS, macOS and Linux).
public final class URLSessionFetcher: HTTPFetching, @unchecked Sendable {
    let session: URLSession

    public init(timeout: TimeInterval = 25) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { data, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status) else { cont.resume(throwing: HTTPError(status: status, url: url)); return }
                cont.resume(returning: data ?? Data())
            }
            task.resume()
        }
    }
}

/// What the NWS knows about a location (office, county, zone, state).
public struct PointInfo: Codable, Hashable, Sendable {
    public var point: GeoPoint
    public var cwa: String           // "OUN"
    public var countyUGC: String?    // "OKC027"
    public var zoneUGC: String?      // "OKZ029"
    public var state: String?        // "OK"
    public var city: String?         // "Norman"
    public var timeZone: String?
    public var officeName: String?

    public var ugcCodes: Set<String> { Set([countyUGC, zoneUGC].compactMap { $0 }) }
}

/// A product listed by the NWS API (id + issuance time).
public struct ProductRef: Hashable, Sendable {
    public var id: String
    public var issued: Date
    public var office: String?
}

/// All data-source endpoints in one place.
public final class WeatherClient: @unchecked Sendable {
    public let fetcher: HTTPFetching
    public var contactInfo: String
    public var mpingAPIKey: String

    public init(fetcher: HTTPFetching = URLSessionFetcher(), contactInfo: String = "", mpingAPIKey: String = "") {
        self.fetcher = fetcher
        self.contactInfo = contactInfo
        self.mpingAPIKey = mpingAPIKey
    }

    var userAgent: String {
        let contact = contactInfo.trimmingCharacters(in: .whitespaces)
        return "StormRadio/1.0 (personal storm alert app\(contact.isEmpty ? "" : "; \(contact)"))"
    }

    func nws(_ path: String) -> URL { URL(string: "https://api.weather.gov\(path)")! }

    func getNWS(_ url: URL) async throws -> Data {
        try await fetcher.get(url, headers: ["User-Agent": userAgent, "Accept": "application/geo+json"])
    }

    func getPlain(_ url: URL) async throws -> Data {
        try await fetcher.get(url, headers: ["User-Agent": userAgent])
    }

    // MARK: NWS alerts

    /// Active alerts, optionally limited to some states (two-letter codes).
    public func activeAlerts(states: [String]? = nil) async throws -> [WeatherAlert] {
        var comps = URLComponents(string: "https://api.weather.gov/alerts/active")!
        var q = [URLQueryItem(name: "status", value: "actual")]
        if let s = states, !s.isEmpty { q.append(URLQueryItem(name: "area", value: s.joined(separator: ","))) }
        comps.queryItems = q
        return try NWSAlertParser.parseCollection(try await getNWS(comps.url!))
    }

    public func pointInfo(_ p: GeoPoint) async throws -> PointInfo {
        let url = nws(String(format: "/points/%.4f,%.4f", p.lat, p.lon))
        let data = try await getNWS(url)
        struct R: Decodable {
            struct P: Decodable {
                var cwa: String?
                var county: String?
                var forecastZone: String?
                var timeZone: String?
                var relativeLocation: RL?
            }
            struct RL: Decodable { var properties: RLP? }
            struct RLP: Decodable { var city: String?; var state: String? }
            var properties: P
        }
        let r = try JSONDecoder().decode(R.self, from: data).properties
        func last(_ s: String?) -> String? { s.flatMap { $0.split(separator: "/").last.map(String.init) } }
        return PointInfo(point: p, cwa: r.cwa ?? "", countyUGC: last(r.county), zoneUGC: last(r.forecastZone),
                         state: r.relativeLocation?.properties?.state ?? last(r.county).map { String($0.prefix(2)) },
                         city: r.relativeLocation?.properties?.city, timeZone: r.timeZone, officeName: nil)
    }

    /// Outline of an NWS zone or county, from its API URL (as listed in `affectedZones`).
    public func zoneShape(_ zoneURL: String) async throws -> GeoShape? {
        guard let url = URL(string: zoneURL) else { return nil }
        struct Z: Decodable { var geometry: GeoJSONGeometry? }
        return try JSONDecoder().decode(Z.self, from: try await getNWS(url)).geometry?.shape
    }

    // MARK: NWS text products

    /// Products of a type, newest first. `location` is e.g. "OUN" for AFDs or "MCD"/"DY1" for SWO.
    public func products(type: String, location: String? = nil) async throws -> [ProductRef] {
        let path = location.map { "/products/types/\(type)/locations/\($0)" } ?? "/products/types/\(type)"
        let data = try await getNWS(nws(path))
        struct R: Decodable {
            struct G: Decodable { var id: String; var issuanceTime: String?; var issuingOffice: String? }
            var graph: [G]?
            enum CodingKeys: String, CodingKey { case graph = "@graph" }
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return (r.graph ?? []).compactMap { g in
            guard let t = WxDate.iso(g.issuanceTime) else { return nil }
            return ProductRef(id: g.id, issued: t, office: g.issuingOffice)
        }.sorted { $0.issued > $1.issued }
    }

    public func productText(id: String) async throws -> String {
        struct R: Decodable { var productText: String? }
        return try JSONDecoder().decode(R.self, from: try await getNWS(nws("/products/\(id)"))).productText ?? ""
    }

    // MARK: SPC outlook GeoJSON

    /// `kind`: "cat", "torn", "wind", "hail" (days 1-2) or "prob" (day 3).
    public func outlookLayer(day: Int, kind: String) async throws -> OutlookLayer {
        let url = URL(string: "https://www.spc.noaa.gov/products/outlook/day\(day)otlk_\(kind).nolyr.geojson")!
        return try OutlookLayer.parse(try await getPlain(url))
    }

    // MARK: Storm reports

    public func localStormReports(hours: Int, states: [String]? = nil) async throws -> [StormReport] {
        var comps = URLComponents(string: "https://mesonet.agron.iastate.edu/geojson/lsr.geojson")!
        var q = [URLQueryItem(name: "hours", value: String(max(1, hours)))]
        if let s = states, !s.isEmpty { q.append(URLQueryItem(name: "states", value: s.joined(separator: ","))) }
        comps.queryItems = q
        return try ReportParsers.parseLSR(try await getPlain(comps.url!))
    }

    public func spotterNetworkReports() async throws -> [StormReport] {
        let data = try await getPlain(URL(string: "https://www.spotternetwork.org/feeds/reports.txt")!)
        return ReportParsers.parseSpotterNetwork(String(decoding: data, as: UTF8.self))
    }

    public func mpingReports(since: Date) async throws -> [StormReport] {
        guard !mpingAPIKey.isEmpty else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var comps = URLComponents(string: "https://mping.ou.edu/mping/api/v2/reports")!
        comps.queryItems = [URLQueryItem(name: "obtime_gte", value: f.string(from: since))]
        let data = try await fetcher.get(comps.url!, headers: [
            "User-Agent": userAgent, "Authorization": "Token \(mpingAPIKey)", "Accept": "application/json",
        ])
        return try ReportParsers.parseMPing(data)
    }
}

// MARK: - US state neighbors (used to limit alert downloads)

public enum StateNeighbors {
    public static let map: [String: [String]] = [
        "AL": ["MS", "TN", "GA", "FL"], "AZ": ["CA", "NV", "UT", "CO", "NM"], "AR": ["MO", "TN", "MS", "LA", "TX", "OK"],
        "CA": ["OR", "NV", "AZ"], "CO": ["WY", "NE", "KS", "OK", "NM", "AZ", "UT"], "CT": ["NY", "MA", "RI"],
        "DE": ["MD", "PA", "NJ"], "DC": ["MD", "VA"], "FL": ["AL", "GA"], "GA": ["FL", "AL", "TN", "NC", "SC"],
        "ID": ["MT", "WY", "UT", "NV", "OR", "WA"], "IL": ["IN", "KY", "MO", "IA", "WI"], "IN": ["MI", "OH", "KY", "IL"],
        "IA": ["MN", "WI", "IL", "MO", "NE", "SD"], "KS": ["NE", "MO", "OK", "CO"], "KY": ["IN", "OH", "WV", "VA", "TN", "MO", "IL"],
        "LA": ["TX", "AR", "MS"], "ME": ["NH"], "MD": ["VA", "WV", "PA", "DE", "DC"], "MA": ["RI", "CT", "NY", "NH", "VT"],
        "MI": ["OH", "IN", "WI"], "MN": ["WI", "IA", "SD", "ND"], "MS": ["LA", "AR", "TN", "AL"],
        "MO": ["IA", "IL", "KY", "TN", "AR", "OK", "KS", "NE"], "MT": ["ND", "SD", "WY", "ID"], "NE": ["SD", "IA", "MO", "KS", "CO", "WY"],
        "NV": ["ID", "UT", "AZ", "CA", "OR"], "NH": ["VT", "ME", "MA"], "NJ": ["DE", "PA", "NY"], "NM": ["AZ", "UT", "CO", "OK", "TX"],
        "NY": ["NJ", "PA", "CT", "MA", "VT"], "NC": ["VA", "TN", "GA", "SC"], "ND": ["MN", "SD", "MT"], "OH": ["PA", "WV", "KY", "IN", "MI"],
        "OK": ["KS", "MO", "AR", "TX", "NM", "CO"], "OR": ["CA", "NV", "ID", "WA"], "PA": ["NY", "NJ", "DE", "MD", "WV", "OH"],
        "RI": ["CT", "MA"], "SC": ["GA", "NC"], "SD": ["ND", "MN", "IA", "NE", "WY", "MT"], "TN": ["KY", "VA", "NC", "GA", "AL", "MS", "AR", "MO"],
        "TX": ["NM", "OK", "AR", "LA"], "UT": ["ID", "WY", "CO", "NM", "AZ", "NV"], "VT": ["NY", "NH", "MA"],
        "VA": ["NC", "TN", "KY", "WV", "MD", "DC"], "WA": ["ID", "OR"], "WV": ["OH", "PA", "MD", "VA", "KY"],
        "WI": ["MI", "MN", "IA", "IL"], "WY": ["MT", "SD", "NE", "CO", "UT", "ID"], "AK": [], "HI": [], "PR": [],
    ]

    public static func withNeighbors(_ states: [String]) -> [String] {
        var out: [String] = []
        for s in states {
            let u = s.uppercased()
            for x in [u] + (map[u] ?? []) where !out.contains(x) { out.append(x) }
        }
        return out
    }
}
