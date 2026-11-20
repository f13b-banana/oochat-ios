import Foundation

// Parses what the Dashboard document's bridge script posts:
// `{ type: "ochat:skill", skill: String, args: String }`, where `args` is the element's
// `data-ochat-args` attribute (an empty string when the attribute is absent).
// `args` stays a string so it can go straight to SkillActionChecker.
enum ControlCenterBridgeMessage {
    static func parse(_ body: Any) -> (skill: String, args: String)? {
        guard let dictionary = body as? [String: Any],
              let skill = dictionary["skill"] as? String, !skill.isEmpty else { return nil }
        guard let raw = dictionary["args"], !(raw is NSNull) else { return (skill, "") }
        guard let args = raw as? String else { return nil }
        return (skill, args)
    }
}
