import Foundation

/// The VTEC action code: what this message does to the event.
public enum VTECAction: String, Codable, Sendable {
    case new = "NEW"   // new event
    case con = "CON"   // continued (no change in time/area besides possible area reduction)
    case ext = "EXT"   // time extended
    case exa = "EXA"   // area expanded
    case exb = "EXB"   // time extended and area expanded
    case upg = "UPG"   // upgraded (this VTEC is the *old* event being replaced)
    case can = "CAN"   // cancelled
    case exp = "EXP"   // expired / will expire
    case cor = "COR"   // correction
    case rou = "ROU"   // routine
    case unknown

    public var isEnding: Bool { self == .can || self == .exp || self == .upg }
}

/// A parsed P-VTEC string, e.g. `/O.NEW.KJAX.SV.W.0261.261003T2339Z-261004T0015Z/`.
public struct VTEC: Codable, Hashable, Sendable {
    public var productClass: String
    public var action: VTECAction
    public var office: String
    public var phenomena: String
    public var significance: String
    public var eventNumber: Int
    public var begin: Date?
    public var end: Date?

    public init(productClass: String, action: VTECAction, office: String, phenomena: String,
                significance: String, eventNumber: Int, begin: Date?, end: Date?) {
        self.productClass = productClass
        self.action = action
        self.office = office
        self.phenomena = phenomena
        self.significance = significance
        self.eventNumber = eventNumber
        self.begin = begin
        self.end = end
    }

    /// Identifies one event across all its messages (issuance, updates, cancellation).
    public var eventKey: String {
        "\(office).\(phenomena).\(significance).\(String(format: "%04d", eventNumber))"
    }

    public static func parse(_ raw: String) -> VTEC? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 7 else { return nil }
        let times = parts[6].split(separator: "-").map(String.init)
        return VTEC(
            productClass: parts[0],
            action: VTECAction(rawValue: parts[1]) ?? .unknown,
            office: parts[2],
            phenomena: parts[3],
            significance: parts[4],
            eventNumber: Int(parts[5]) ?? 0,
            begin: times.first.flatMap(WxDate.vtec),
            end: times.count > 1 ? WxDate.vtec(times[1]) : nil
        )
    }
}
