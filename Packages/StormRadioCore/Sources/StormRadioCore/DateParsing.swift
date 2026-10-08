import Foundation

/// Date helpers for the various timestamp formats used by NWS/SPC/IEM feeds.
public enum WxDate {
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    private static let vtecFormatter = utcFormatter("yyMMdd'T'HHmm'Z'")
    private static let compactFormatter = utcFormatter("yyyyMMddHHmm")
    private static let spaceFormatter = utcFormatter("yyyy-MM-dd HH:mm:ss")

    /// Parses ISO-8601 timestamps such as `2026-10-08T18:53:00-04:00`, `...Z`, `...-00:00` or with fractions.
    public static func iso(_ s: String?) -> Date? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("-00:00") { s = String(s.dropLast(6)) + "Z" }
        if let d = isoPlain.date(from: s) { return d }
        if let d = isoFractional.date(from: s) { return d }
        // e.g. "2026-10-08T21:00:00" without zone -> assume UTC
        if s.count == 19, let d = isoPlain.date(from: s + "Z") { return d }
        return nil
    }

    /// Parses VTEC times like `261004T2130Z`; `000000T0000Z` means "not specified".
    public static func vtec(_ s: String) -> Date? {
        if s.hasPrefix("000000") { return nil }
        return vtecFormatter.date(from: s)
    }

    /// Parses `yyyyMMddHHmm` UTC stamps (IEM product ids, SPC geojson ISSUE fields).
    public static func compact(_ s: String) -> Date? {
        compactFormatter.date(from: String(s.prefix(12)))
    }

    /// Parses `yyyy-MM-dd HH:mm:ss` (UTC), optionally followed by " UTC".
    public static func spaced(_ s: String) -> Date? {
        let t = s.replacingOccurrences(of: " UTC", with: "").trimmingCharacters(in: .whitespaces)
        return spaceFormatter.date(from: t)
    }

    public static func isoString(_ d: Date) -> String { isoPlain.string(from: d) }
}
