import Foundation

/// One agent on the Giving Device, as a link carries it: its lower-cased 0x Address and its Agent Name.
/// Nothing else travels (no avatar colour, no connection settings).
public struct DeviceLinkAgentName: Codable, Equatable, Sendable {
    public let address: String
    public let name: String

    /// Nil unless `address` is a 0x Address. Stores it lower-cased.
    public init?(address: String, name: String) {
        guard let address = AgentAddress.normalized(address) else { return nil }
        self.address = address
        self.name = name
    }

    /// The Receiving Device's rule. `renames` are the indices in `agents` whose Address is in the list, with the
    /// giver's name (an unchanged name included, so callers need not compare); `additions` are the entries no
    /// agent has, one per Address. Every other agent stays as it is.
    public static func apply<Agent>(
        _ list: [Self],
        to agents: [Agent],
        address: (Agent) -> String?
    ) -> (renames: [(index: Int, name: String)], additions: [Self]) {
        let addresses = agents.map { address($0).flatMap(AgentAddress.normalized) }
        var renames: [(index: Int, name: String)] = []
        var additions: [Self] = []
        for entry in list {
            guard let index = addresses.firstIndex(of: entry.address) else {
                // One agent per Address, even if the list names it twice: the first entry wins.
                if !additions.contains(where: { $0.address == entry.address }) { additions.append(entry) }
                continue
            }
            renames.append((index, entry.name))
        }
        return (renames, additions)
    }

    /// Agents that share an Address: the first in `agents` keeps it and the rest are extras to merge into it.
    /// Pass agents earliest-created first. Only groups with extras; agents with no Address are never grouped.
    public static func duplicates<Agent>(
        in agents: [Agent],
        address: (Agent) -> String?
    ) -> [(keep: Agent, extras: [Agent])] {
        var groups: [String: (keep: Agent, extras: [Agent])] = [:]
        var order: [String] = []
        for agent in agents {
            guard let key = address(agent).flatMap(AgentAddress.normalized) else { continue }
            if groups[key] == nil {
                groups[key] = (agent, [])
                order.append(key)
            } else {
                groups[key]?.extras.append(agent)
            }
        }
        return order.compactMap { groups[$0] }.filter { !$0.extras.isEmpty }
    }
}
