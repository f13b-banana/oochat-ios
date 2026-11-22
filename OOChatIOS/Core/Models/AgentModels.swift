import Foundation

/// Result of checking whether an agent can be reached.
/// `unknown` leaves the last known presence unchanged.
enum AgentAvailability: Equatable, Sendable {
    case online
    case offline
    case unknown
}

struct SavedAgent: Identifiable, Equatable {
    let id: String
    var name: String
    var address: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        address: String,
        name: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.address = address
        self.name = name ?? Self.defaultName(for: address)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func defaultName(for address: String) -> String {
        guard address.count > 16 else {
            return address.isEmpty ? "Agent" : "Agent \(address)"
        }
        return "Agent \(address.prefix(8))...\(address.suffix(6))"
    }

    /// The name the sidebar shows. A blank name says "Agent"; the default name (the address) is
    /// shortened to 0x1234...abcd.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Agent"
        }
        guard trimmed == Self.defaultName(for: address), address.count > 12 else {
            return trimmed
        }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }
}
