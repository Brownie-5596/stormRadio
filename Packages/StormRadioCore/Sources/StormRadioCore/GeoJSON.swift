import Foundation

/// Minimal GeoJSON geometry decoding (Point, Polygon, MultiPolygon, LineString).
public enum GeoJSONGeometry: Decodable {
    case point(GeoPoint)
    case shape(GeoShape)
    case line([GeoPoint])
    case other

    enum CodingKeys: String, CodingKey { case type, coordinates, geometries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "Point":
            let v = try c.decode([Double].self, forKey: .coordinates)
            guard v.count >= 2 else { self = .other; return }
            self = .point(GeoPoint(lat: v[1], lon: v[0]))
        case "LineString":
            let v = try c.decode([[Double]].self, forKey: .coordinates)
            self = .line(v.compactMap(Self.pt))
        case "Polygon":
            let v = try c.decode([[[Double]]].self, forKey: .coordinates)
            self = .shape(GeoShape(polygons: [Self.polygon(v)]))
        case "MultiPolygon":
            let v = try c.decode([[[[Double]]]].self, forKey: .coordinates)
            self = .shape(GeoShape(polygons: v.map(Self.polygon)))
        case "GeometryCollection":
            let geoms = (try? c.decode([GeoJSONGeometry].self, forKey: .geometries)) ?? []
            let polys = geoms.flatMap { g -> [GeoPolygon] in
                if case .shape(let s) = g { return s.polygons }
                return []
            }
            self = polys.isEmpty ? .other : .shape(GeoShape(polygons: polys))
        default:
            self = .other
        }
    }

    static func pt(_ v: [Double]) -> GeoPoint? {
        v.count >= 2 ? GeoPoint(lat: v[1], lon: v[0]) : nil
    }

    static func polygon(_ rings: [[[Double]]]) -> GeoPolygon {
        let converted = rings.map { ring -> [GeoPoint] in
            var pts = ring.compactMap(pt)
            if pts.count > 1, pts.first == pts.last { pts.removeLast() }
            return pts
        }
        return GeoPolygon(outer: converted.first ?? [], holes: Array(converted.dropFirst()))
    }

    public var shape: GeoShape? {
        if case .shape(let s) = self { return s }
        return nil
    }

    public var point: GeoPoint? {
        if case .point(let p) = self { return p }
        return nil
    }
}

/// Decodes either a single string or an array of strings (NWS parameters are arrays).
struct StringOrArray: Decodable {
    var values: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode([String].self) { values = a }
        else if let s = try? c.decode(String.self) { values = [s] }
        else if let n = try? c.decode(Double.self) { values = [String(n)] }
        else { values = [] }
    }
}

/// A JSON value that may be a string or a number (IEM uses both for magnitudes).
struct LooseString: Decodable {
    var value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = nil }
    }
}
