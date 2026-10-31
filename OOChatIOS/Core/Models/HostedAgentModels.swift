import Foundation
import ConnectOnionKit

struct AgentSkill: Identifiable, Decodable, Equatable {
    let name: String
    let description: String
    let location: String?

    var id: String {
        name
    }

    init(name: String, description: String = "", location: String? = nil) {
        self.name = name
        self.description = description
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case location
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        location = try container.decodeIfPresent(String.self, forKey: .location)
    }
}

struct AgentProfile: Decodable {
    let alias: String?
    let skills: [AgentSkill]?
}

struct AgentInfo: Decodable {
    let address: String?
    let name: String?
    let endpoints: [String]?
    let skills: [AgentSkill]?
    let profile: AgentProfile?
    let online: Bool?

    var advertisedSkills: [AgentSkill] {
        skills ?? profile?.skills ?? []
    }

    var advertisedName: String? {
        [name, profile?.alias]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

struct ResolvedEndpoint {
    enum Kind {
        case direct
        case relay
    }

    let wsURL: URL
    let kind: Kind
    let label: String
}

struct HostedAgentResult {
    let output: String?
    let endpointLabel: String
    let serverSession: [String: JSONValue]?
    var sessionModes: OIPSessionModes?
}
