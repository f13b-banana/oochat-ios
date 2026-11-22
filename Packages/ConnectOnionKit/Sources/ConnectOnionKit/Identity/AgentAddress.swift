import Foundation

/// The rules for a 0x Address: "0x" and 64 hex digits, compared without regard to case.
public enum AgentAddress {
    /// "0x" and 64 hex digits, in any case, lower-cased; nil for anything else (a Direct URL, say).
    /// Each device keeps one agent per normalised Address.
    public static func normalized(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        return lowered.range(of: #"^0x[0-9a-f]{64}\z"#, options: .regularExpression) == nil ? nil : lowered
    }

    /// Whether two Addresses are the same one, ignoring case. Nil never matches.
    public static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.lowercased() == rhs.lowercased()
    }
}
