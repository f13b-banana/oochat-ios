import Foundation

/// Decides what a Control Center skill button may send. Plain function; input -> answer, never sends.
///
/// The rules match O Chat `components/dashboard/dashboard-pane.tsx`:
/// - the skill list from AGENT_PROFILE must have arrived, and an empty list refuses everything;
/// - the name must look like `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$` since written into chat message;
/// - the name must be one of the agent's own skills;
/// - the arguments lose their line breaks and repeated spaces and are cut to 500 characters.

public enum SkillActionChecker {
    /// The longest argument text that is sent (characters)
    public static let maxArgumentLength = 500
    /// The longest skill name the host accepts.
    public static let maxNameLength = 64

    public enum Outcome: Equatable, Sendable {
        /// The INPUT text to send: `/skill`, or `/skill args` when there are arguments.
        case send(String)
        case refused(Refusal)
    }

    public enum Refusal: Equatable, Sendable {
        /// AGENT_PROFILE has not arrived yet, or it listed no skills.
        case profileNotLoaded
        case invalidName
        case unknownSkill(String)

        /// Words a notice can show next to the button.
        public var message: String {
            switch self {
            case .profileNotLoaded:
                return "The agent's skills have not loaded yet."
            case .invalidName:
                return "That is not a valid skill name."
            case .unknownSkill(let name):
                return "The agent has no skill called \(name)."
            }
        }
    }

    /// `availableSkills` is `profile?.skills`; nil while no AGENT_PROFILE has arrived.
    public static func check(
        skill: String,
        args: String?,
        availableSkills: [OIPAgentSkill]?
    ) -> Outcome {
        guard let available = availableSkills, !available.isEmpty else {
            return .refused(.profileNotLoaded)
        }
        guard isValidName(skill) else {
            return .refused(.invalidName)
        }
        guard available.contains(where: { $0.name == skill }) else {
            return .refused(.unknownSkill(skill))
        }

        let cleaned = cleanArguments(args)
        return .send(cleaned.isEmpty ? "/\(skill)" : "/\(skill) \(cleaned)")
    }

    /// `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`; checked on the bytes so only plain ASCII passes.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= maxNameLength, isAlphanumeric(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { isAlphanumeric($0) || $0 == underscore || $0 == hyphen }
    }

    /// All runs of whitespace, becomes one space; the ends are trimmed.
    /// Text is cut to `maxArgumentLength` characters.
    public static func cleanArguments(_ args: String?) -> String {
        guard let args else { return "" }
        let collapsed = args.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(maxArgumentLength))
    }

    private static let underscore: UInt8 = 0x5F
    private static let hyphen: UInt8 = 0x2D

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
