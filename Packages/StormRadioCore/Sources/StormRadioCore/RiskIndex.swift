import Foundation

/// A simple 0-5 danger index used for path alerts and priority boosts.
///
/// 1 = basic severe (≤1" hail, ≤60 mph), 2 = notable (1.25-1.75" / 70 mph / tornado possible),
/// 3 = significant (≥2" hail, ≥80 mph, considerable), 4 = tornado (radar) / destructive / ≥2.75" hail,
/// 5 = observed tornado, PDS, emergency.
public enum RiskIndex {
    public static func score(_ a: WeatherAlert) -> Int {
        var r = 0
        switch a.event {
        case "Special Weather Statement": r = 0
        case "Severe Thunderstorm Warning": r = 1
        case "Tornado Warning": r = 4
        case "Extreme Wind Warning": r = 5
        case "Flash Flood Warning": r = 2
        default: r = 0
        }
        if let h = a.maxHailInches {
            if h >= 2.75 { r = max(r, 4) } else if h >= 2.0 { r = max(r, 3) } else if h >= 1.25 { r = max(r, 2) } else if h >= 1.0 { r = max(r, 1) }
        }
        if let w = a.maxWindMPH {
            if w >= 90 { r = max(r, 4) } else if w >= 80 { r = max(r, 3) } else if w >= 70 { r = max(r, 2) } else if w >= 58 { r = max(r, 1) }
        }
        switch a.tornadoDetection {
        case .possible: r = max(r, 2)
        case .radarIndicated: r = max(r, 4)
        case .observed, .radarConfirmed: r = max(r, 5)
        case .unknown: break
        }
        switch a.thunderstormDamage {
        case .considerable: r = max(r, 3)
        case .destructive: r = max(r, 4)
        default: break
        }
        if a.tornadoDamage >= .considerable { r = 5 }
        if a.flashFloodDamage == .considerable { r = max(r, 3) }
        if a.isPDS || a.isEmergency { r = 5 }
        return min(r, 5)
    }

    public static func label(_ r: Int) -> String {
        switch r {
        case 5: return "extreme"
        case 4: return "very high"
        case 3: return "high"
        case 2: return "moderate"
        case 1: return "low"
        default: return "minimal"
        }
    }
}
