import Foundation

/// A latitude/longitude pair in decimal degrees.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// A polygon made of an outer ring and optional holes. Rings do not need to be closed.
public struct GeoPolygon: Codable, Hashable, Sendable {
    public var outer: [GeoPoint]
    public var holes: [[GeoPoint]]

    public init(outer: [GeoPoint], holes: [[GeoPoint]] = []) {
        self.outer = outer
        self.holes = holes
    }
}

/// One or more polygons (a GeoJSON Polygon or MultiPolygon).
public struct GeoShape: Codable, Hashable, Sendable {
    public var polygons: [GeoPolygon]

    public init(polygons: [GeoPolygon]) {
        self.polygons = polygons
    }

    public init(ring: [GeoPoint]) {
        self.polygons = [GeoPolygon(outer: ring)]
    }

    public var isEmpty: Bool { polygons.allSatisfy { $0.outer.count < 3 } }

    public var allPoints: [GeoPoint] { polygons.flatMap { $0.outer } }
}

public enum Geo {
    public static let earthRadiusMiles = 3958.8
    public static let kmPerMile = 1.609344
    public static let mphPerKnot = 1.150779

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Great-circle distance in statute miles.
    public static func distanceMiles(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = rad(b.lat - a.lat)
        let dLon = rad(b.lon - a.lon)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMiles * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b` in degrees clockwise from true north (0..<360).
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = rad(a.lat), φ2 = rad(b.lat)
        let Δλ = rad(b.lon - a.lon)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return normalizeDegrees(deg(atan2(y, x)))
    }

    public static func normalizeDegrees(_ d: Double) -> Double {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    /// Point reached travelling `miles` from `start` along `bearingDegrees`.
    public static func destination(from start: GeoPoint, bearingDegrees: Double, miles: Double) -> GeoPoint {
        let δ = miles / earthRadiusMiles
        let θ = rad(bearingDegrees)
        let φ1 = rad(start.lat), λ1 = rad(start.lon)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        var lon = deg(λ2)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return GeoPoint(lat: deg(φ2), lon: lon)
    }

    // MARK: Local flat projection (miles east/north of an origin). Accurate enough within a few hundred miles.

    public struct LocalXY: Hashable {
        public var x: Double // miles east
        public var y: Double // miles north
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public static func project(_ p: GeoPoint, origin: GeoPoint) -> LocalXY {
        let milesPerDegLat = 69.0
        let milesPerDegLon = 69.172 * cos(rad(origin.lat))
        var dLon = p.lon - origin.lon
        if dLon > 180 { dLon -= 360 }
        if dLon < -180 { dLon += 360 }
        return LocalXY(x: dLon * milesPerDegLon, y: (p.lat - origin.lat) * milesPerDegLat)
    }

    public static func unproject(_ xy: LocalXY, origin: GeoPoint) -> GeoPoint {
        let milesPerDegLat = 69.0
        let milesPerDegLon = max(0.0001, 69.172 * cos(rad(origin.lat)))
        return GeoPoint(lat: origin.lat + xy.y / milesPerDegLat, lon: origin.lon + xy.x / milesPerDegLon)
    }

    // MARK: Containment

    public static func ringContains(_ ring: [GeoPoint], _ p: GeoPoint) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat) {
                let xCross = (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon
                if p.lon < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    public static func contains(_ polygon: GeoPolygon, _ p: GeoPoint) -> Bool {
        guard ringContains(polygon.outer, p) else { return false }
        for hole in polygon.holes where ringContains(hole, p) { return false }
        return true
    }

    public static func contains(_ shape: GeoShape, _ p: GeoPoint) -> Bool {
        shape.polygons.contains { contains($0, p) }
    }

    // MARK: Distance to shapes

    /// Result of measuring from a point to a shape.
    public struct ShapeDistance: Hashable {
        /// Miles from the point to the nearest part of the shape (0 when inside).
        public var miles: Double
        /// The nearest point on the shape boundary (or the point itself when inside).
        public var nearest: GeoPoint
        public var inside: Bool
    }

    /// Distance from `p` to the nearest edge of `shape` (0 if inside).
    public static func distance(from p: GeoPoint, to shape: GeoShape) -> ShapeDistance? {
        if shape.isEmpty { return nil }
        if contains(shape, p) { return ShapeDistance(miles: 0, nearest: p, inside: true) }
        var best: (Double, LocalXY)? = nil
        for poly in shape.polygons {
            let ring = poly.outer
            guard ring.count >= 2 else { continue }
            let pts = ring.map { project($0, origin: p) }
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                let q = closestPointOnSegment(LocalXY(x: 0, y: 0), a, b)
                let d = hypot(q.x, q.y)
                if best == nil || d < best!.0 { best = (d, q) }
            }
        }
        guard let (_, q) = best else { return nil }
        let nearest = unproject(q, origin: p)
        return ShapeDistance(miles: distanceMiles(p, nearest), nearest: nearest, inside: false)
    }

    static func closestPointOnSegment(_ p: LocalXY, _ a: LocalXY, _ b: LocalXY) -> LocalXY {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        if len2 == 0 { return a }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
        t = max(0, min(1, t))
        return LocalXY(x: a.x + t * abx, y: a.y + t * aby)
    }

    /// Area-weighted centroid of the shape (falls back to vertex average).
    public static func centroid(_ shape: GeoShape) -> GeoPoint? {
        let pts = shape.allPoints
        guard let first = pts.first else { return nil }
        var sx = 0.0, sy = 0.0, sa = 0.0
        for poly in shape.polygons {
            let r = poly.outer.map { project($0, origin: first) }
            guard r.count >= 3 else { continue }
            for i in 0..<r.count {
                let a = r[i], b = r[(i + 1) % r.count]
                let c = a.x * b.y - b.x * a.y
                sa += c
                sx += (a.x + b.x) * c
                sy += (a.y + b.y) * c
            }
        }
        if abs(sa) < 1e-9 {
            let lat = pts.map { $0.lat }.reduce(0, +) / Double(pts.count)
            let lon = pts.map { $0.lon }.reduce(0, +) / Double(pts.count)
            return GeoPoint(lat: lat, lon: lon)
        }
        let a = sa / 2
        return unproject(LocalXY(x: sx / (6 * a), y: sy / (6 * a)), origin: first)
    }

    /// Approximate area in square miles.
    public static func areaSquareMiles(_ shape: GeoShape) -> Double {
        guard let origin = shape.allPoints.first else { return 0 }
        var total = 0.0
        for poly in shape.polygons {
            total += abs(ringArea(poly.outer.map { project($0, origin: origin) }))
            for h in poly.holes { total -= abs(ringArea(h.map { project($0, origin: origin) })) }
        }
        return max(0, total)
    }

    static func ringArea(_ r: [LocalXY]) -> Double {
        guard r.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<r.count {
            let a = r[i], b = r[(i + 1) % r.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    /// True if two shapes overlap at all (vertex containment or edge crossing).
    public static func intersects(_ a: GeoShape, _ b: GeoShape) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        for p in a.allPoints where contains(b, p) { return true }
        for p in b.allPoints where contains(a, p) { return true }
        for pa in a.polygons {
            for pb in b.polygons where ringsCross(pa.outer, pb.outer) { return true }
        }
        return false
    }

    static func ringsCross(_ r1: [GeoPoint], _ r2: [GeoPoint]) -> Bool {
        guard r1.count >= 2, r2.count >= 2 else { return false }
        for i in 0..<r1.count {
            let a = r1[i], b = r1[(i + 1) % r1.count]
            for j in 0..<r2.count {
                let c = r2[j], d = r2[(j + 1) % r2.count]
                if segmentsIntersect(a, b, c, d) { return true }
            }
        }
        return false
    }

    static func segmentsIntersect(_ p1: GeoPoint, _ p2: GeoPoint, _ p3: GeoPoint, _ p4: GeoPoint) -> Bool {
        func orient(_ a: GeoPoint, _ b: GeoPoint, _ c: GeoPoint) -> Double {
            (b.lon - a.lon) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lon - a.lon)
        }
        let d1 = orient(p3, p4, p1), d2 = orient(p3, p4, p2)
        let d3 = orient(p1, p2, p3), d4 = orient(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Bounding box (minLat, minLon, maxLat, maxLon).
    public static func bounds(_ points: [GeoPoint]) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)? {
        guard let f = points.first else { return nil }
        var r = (minLat: f.lat, minLon: f.lon, maxLat: f.lat, maxLon: f.lon)
        for p in points {
            r.minLat = min(r.minLat, p.lat); r.maxLat = max(r.maxLat, p.lat)
            r.minLon = min(r.minLon, p.lon); r.maxLon = max(r.maxLon, p.lon)
        }
        return r
    }

    /// A circle approximated as a polygon (useful for drawing a radius).
    public static func circle(center: GeoPoint, radiusMiles: Double, segments: Int = 64) -> [GeoPoint] {
        (0..<segments).map { i in
            destination(from: center, bearingDegrees: Double(i) * 360 / Double(segments), miles: radiusMiles)
        }
    }
}

// MARK: - Compass directions

public enum CompassStyle: String, Codable, CaseIterable, Sendable {
    case eight = "8"
    case sixteen = "16"
}

public enum Compass {
    static let names16 = ["north", "north-northeast", "northeast", "east-northeast",
                          "east", "east-southeast", "southeast", "south-southeast",
                          "south", "south-southwest", "southwest", "west-southwest",
                          "west", "west-northwest", "northwest", "north-northwest"]
    static let names8 = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
    static let abbrev16 = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                           "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    /// Spoken compass name for a bearing, e.g. "northeast".
    public static func name(for degrees: Double, style: CompassStyle = .eight) -> String {
        let d = Geo.normalizeDegrees(degrees)
        switch style {
        case .eight:
            return names8[Int((d + 22.5) / 45) % 8]
        case .sixteen:
            return names16[Int((d + 11.25) / 22.5) % 16]
        }
    }

    public static func abbreviation(for degrees: Double) -> String {
        abbrev16[Int((Geo.normalizeDegrees(degrees) + 11.25) / 22.5) % 16]
    }

    /// Converts an abbreviation like "ENE" to its spoken form ("east-northeast").
    public static func spoken(abbreviation: String) -> String? {
        guard let i = abbrev16.firstIndex(of: abbreviation.uppercased()) else { return nil }
        return names16[i]
    }

    public static func degrees(abbreviation: String) -> Double? {
        guard let i = abbrev16.firstIndex(of: abbreviation.uppercased()) else { return nil }
        return Double(i) * 22.5
    }
}
