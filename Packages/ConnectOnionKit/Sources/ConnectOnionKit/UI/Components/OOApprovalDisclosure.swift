import Foundation

/// The plain-language lines an approval shows between the action and its buttons.
public enum OOApprovalDisclosure {
    public enum Effect: Sendable, Equatable {
        case runsCommand
        case changesFiles
        case usesNetwork
        case other
    }

    private static let commandKeys = ["cmd", "command", "script"]
    private static let pathKeys = ["path", "file_path", "filepath", "file", "filename"]

    private static let commandTools: Set<String> = [
        "bash", "shell", "run", "run_in_dir", "run_background", "run_command", "terminal", "exec"
    ]
    private static let fileEditTools: Set<String> = [
        "write", "edit", "multi_edit", "write_file", "edit_file", "create_file", "apply_patch"
    ]
    private static let networkTools: Set<String> = [
        "web_fetch", "fetch", "fetch_url", "http_request"
    ]

    /// What the person is agreeing to if they allow the call. The whole tool name has to match.
    public static func effect(tool: String, arguments: [String: JSONValue]) -> Effect {
        let name = tool.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if commandTools.contains(name) || command(in: arguments) != nil {
            return .runsCommand
        }
        if fileEditTools.contains(name) {
            return .changesFiles
        }
        if networkTools.contains(name) {
            return .usesNetwork
        }
        return .other
    }

    /// what this one approval covers
    public static func scope(tool: String, arguments: [String: JSONValue]) -> String {
        switch effect(tool: tool, arguments: arguments) {
        case .runsCommand:
            return "This command, once."
        case .changesFiles:
            if let path = firstString(pathKeys, in: arguments) {
                return "This call only, on \(path)."
            }
            return "This call only."
        case .usesNetwork:
            if let url = arguments["url"]?.stringValue {
                return "This call only, to \(url)."
            }
            return "This call only."
        case .other:
            return "This call only."
        }
    }

    /// What happens if the person taps Allow once
    public static func consequence(tool: String, arguments: [String: JSONValue]) -> String {
        switch effect(tool: tool, arguments: arguments) {
        case .runsCommand:
            return "Runs on the agent's host with its permissions. It can change files or settings, and that may not be undoable."
        case .changesFiles:
            return "Changes files on the agent's host. Check the path before you allow it."
        case .usesNetwork:
            return "Sends a request over the network from the agent's host."
        case .other:
            return unrecognisedConsequence
        }
    }

    /// Said for every tool the app does not recognise. It makes no claim about what the tool does.
    public static let unrecognisedConsequence =
        "The app does not recognise this tool, so it cannot say what it will change. Review the parameters before you allow it."

    /// The label on the wider-grant button. The host trusts a whole tool, not one command,
    /// so the label names the tool, for example "Trust all bash calls".
    public static func trustTitle(tool: String) -> String {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Trust this tool" : "Trust all \(name) calls"
    }

    /// What the wider grant covers, shown on the confirmation step
    public static func trustScope(tool: String) -> String {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = name.isEmpty ? "this tool" : name
        return "Every later request to use \(subject) runs without asking until this session ends, "
            + "whatever it asks to do. You can still stop the response at any time."
    }

    private static func command(in arguments: [String: JSONValue]) -> String? {
        firstString(commandKeys, in: arguments)
    }

    private static func firstString(_ keys: [String], in arguments: [String: JSONValue]) -> String? {
        for key in keys {
            if let value = arguments[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
