import Foundation

/// Helpers that turn numbers, times and distances into text that reads well aloud.
public enum Spoken {
    public static func plural(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit)" : "\(n) \(unit)s"
    }

    /// "50 minutes", "1 hour", "1 hour and 20 minutes".
    public static func duration(minutes m: Int) -> String {
        if m < 60 { return plural(max(m, 0), "minute") }
        let h = m / 60, r = m % 60
        return r == 0 ? plural(h, "hour") : "\(plural(h, "hour")) and \(plural(r, "minute"))"
    }

    public static func minutesBetween(_ a: Date, _ b: Date) -> Int {
        Int((b.timeIntervalSince(a) / 60).rounded())
    }

    /// "7:30", "7:30 PM" or "19:30".
    public static func clock(_ d: Date, use24Hour: Bool, sayAMPM: Bool, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        if use24Hour {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = sayAMPM ? "h:mm a" : "h:mm"
        }
        return f.string(from: d)
    }

    /// "less than a mile", "1 mile", "6 miles".
    public static func distance(_ miles: Double) -> String {
        if miles < 1 { return "less than a mile" }
        let m = Int(miles.rounded())
        return plural(m, "mile")
    }

    /// "60 mile per hour"
    public static func windAdjective(_ mph: Int) -> String { "\(mph) mile per hour" }

    public static let hailObjects: [(Double, String)] = [
        (0.25, "pea"), (0.5, "marble"), (0.75, "penny"), (0.88, "nickel"), (1.0, "quarter"), (1.25, "half dollar"),
        (1.5, "ping pong ball"), (1.75, "golf ball"), (2.0, "hen egg"), (2.5, "tennis ball"), (2.75, "baseball"),
        (3.0, "tea cup"), (4.0, "softball"), (4.5, "grapefruit"),
    ]

    public static func hailObject(_ inches: Double) -> String? {
        hailObjects.last(where: { inches + 0.001 >= $0.0 })?.1
    }

    /// "2 inch", "1 and a half inch", "three quarter inch".
    public static func inches(_ v: Double) -> String {
        let whole = Int(v)
        let frac = v - Double(whole)
        func near(_ x: Double) -> Bool { abs(frac - x) < 0.02 }
        let w = whole == 0 ? "" : "\(whole)"
        if near(0) { return "\(whole) inch" }
        if near(0.25) { return whole == 0 ? "quarter inch" : "\(w) and a quarter inch" }
        if near(0.5) { return whole == 0 ? "half inch" : "\(w) and a half inch" }
        if near(0.75) { return whole == 0 ? "three quarter inch" : "\(w) and three quarter inch" }
        if near(0.88) && whole == 0 { return "7 eighths inch" }
        return String(format: "%.2f inch", v).replacingOccurrences(of: "0 inch", with: " inch").replacingOccurrences(of: "  ", with: " ")
    }

    /// "2 inch, hen egg size hail"
    public static func hail(_ inches: Double, style: HailStyle) -> String {
        let obj = hailObject(inches)
        switch style {
        case .inches: return "\(self.inches(inches)) hail"
        case .object: return obj.map { "\($0) size hail" } ?? "\(self.inches(inches)) hail"
        case .inchesAndObject: return obj.map { "\(self.inches(inches)), \($0) size hail" } ?? "\(self.inches(inches)) hail"
        }
    }

    /// "a, b and c"
    public static func list(_ items: [String], conjunction: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items.last!
        }
    }

    public static func article(for word: String) -> String {
        guard let c = word.lowercased().first else { return "a" }
        return "aeiou".contains(c) ? "an" : "a"
    }

    public static func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// Converts SHOUTING NWS text to sentence case.
    public static func sentenceCase(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        var capNext = true
        for ch in lower {
            if capNext, ch.isLetter { out.append(contentsOf: ch.uppercased()); capNext = false } else { out.append(ch) }
            if ch == "." || ch == "!" || ch == "?" { capNext = true }
        }
        return out
    }

    /// Light normalization so the speech engine reads weather text well.
    public static func normalizeForSpeech(_ s: String) -> String {
        var t = s
        if let re = try? NSRegularExpression(pattern: "(https?:/?/?|www\\.)\\S+", options: [.caseInsensitive]) {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "the link in the product")
        }
        let replacements: [(String, String)] = [
            ("\n", " "), ("...", ", "), (" mph", " miles per hour"), ("MPH", "miles per hour"), (" kt ", " knots "), (" kts", " knots"),
            (" NWS ", " N W S "), ("&&", ""), (" ft ", " feet "), (" in.", " inch"), ("°", " degrees"),
        ]
        for (a, b) in replacements { t = t.replacingOccurrences(of: a, with: b) }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: ",,", with: ",")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "2 ENE Mcintyre" -> "2 miles east-northeast of Mcintyre"
    public static func lsrPlace(_ s: String) -> String {
        let parts = s.split(separator: " ", maxSplits: 2).map(String.init)
        if parts.count == 3, let n = Double(parts[0]), let dir = Compass.spoken(abbreviation: parts[1]) {
            return "\(distance(n)) \(dir) of \(parts[2])"
        }
        return s
    }

    /// Joins sentence fragments, adds periods and tidies whitespace/punctuation.
    public static func joinSentences(_ parts: [String]) -> String {
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let withPeriods = cleaned.map { p -> String in
            let s = capitalizeFirst(p)
            if let last = s.last, ".!?".contains(last) { return s }
            return s + "."
        }
        return withPeriods.joined(separator: " ")
    }

    /// Cleans up text produced by filling a custom format string with possibly-empty placeholders.
    public static func tidy(_ s: String) -> String {
        var t = s
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        let fixes: [(String, String)] = [(" .", "."), (" ,", ","), ("..", "."), (". .", "."), (",.", "."), (".,", "."), (", ,", ",")]
        var changed = true
        while changed {
            changed = false
            for (a, b) in fixes where t.contains(a) {
                t = t.replacingOccurrences(of: a, with: b)
                changed = true
            }
            while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        }
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        if t.hasPrefix(".") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces)
        // Capitalize after sentence ends.
        var out = ""
        var capNext = true
        for ch in t {
            if capNext, ch.isLetter { out.append(contentsOf: ch.uppercased()); capNext = false; continue }
            if ch.isLetter || ch.isNumber { capNext = false }
            out.append(ch)
            if ch == "." || ch == "!" || ch == "?" { capNext = true }
        }
        return out
    }
}
