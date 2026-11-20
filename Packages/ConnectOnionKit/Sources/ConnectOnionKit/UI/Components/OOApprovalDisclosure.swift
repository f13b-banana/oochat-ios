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

    /// What the wider grant covers, shown on the confirmation step. The tool name is used as a
    /// noun ("bash call"), as in trustTitle, so a name like "write" is not read as a verb.
    public static func trustScope(tool: String) -> String {
        let name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = name.isEmpty ? "call to this tool" : "\(name) call"
        return "Every later \(subject) runs without asking until this session ends, "
            + "whatever it asks to do. You can still stop the response at any time."
    }

    /// One sentence saying what the call will do, used as the title of the approval.
    /// Moved here from the macOS app so both apps say the same thing; wording unchanged.
    public static func summary(tool: String, arguments: [String: JSONValue]) -> String {
        let name = tool.lowercased()
        let target = firstString(summaryTargetKeys, in: arguments).map(shortTarget)

        if let line = phrase(for: name, target: target, in: fileSummaries) {
            return line
        }
        if ["shell", "command", "execute", "bash"].contains(where: name.contains),
           let command = command(in: arguments) {
            return explain(command: command)
        }
        if let line = phrase(for: name, target: target, in: messageSummaries) {
            return line
        }
        if name.contains("click") {
            return "Interact with the currently open webpage."
        }
        return "Allow the agent to run \(tool)."
    }

    /// A tool-name match and the sentence it gives, with `{target}` replaced by the short target.
    private struct SummaryRule: Sendable {
        let terms: [String]
        let withTarget: String
        let fallback: String
    }

    private static let fileSummaries = [
        SummaryRule(terms: ["delete", "remove", "unlink"], withTarget: "Delete {target}.",
                    fallback: "Delete the selected item."),
        SummaryRule(terms: ["write"], withTarget: "Create or replace {target} with the content supplied by the agent.",
                    fallback: "Write content to a file."),
        SummaryRule(terms: ["edit", "update", "patch"], withTarget: "Modify {target} using the agent’s proposed changes.",
                    fallback: "Modify an existing file or resource."),
        SummaryRule(terms: ["create"], withTarget: "Create {target}.",
                    fallback: "Create a new file or resource."),
        SummaryRule(terms: ["move", "rename"], withTarget: "Move or rename {target}.",
                    fallback: "Move or rename a file or resource.")
    ]

    private static let messageSummaries = [
        SummaryRule(terms: ["send", "reply"], withTarget: "Send information to {target}.",
                    fallback: "Send information to an external recipient."),
        SummaryRule(terms: ["upload"], withTarget: "Upload a file to {target}.",
                    fallback: "Upload a file to an external service.")
    ]

    private static let summaryTargetKeys = [
        "path", "file_path", "filepath", "filename", "target", "url",
        "command", "recipient", "to", "event_id"
    ]

    private static let commandSummaries = [
        "rm": "Delete the files or folders named by this command.",
        "mkdir": "Create one or more folders.",
        "touch": "Create an empty file or update its modified time.",
        "cp": "Copy files or folders to another location.",
        "mv": "Move or rename files or folders.",
        "python": "Run a Python program or script.",
        "python3": "Run a Python program or script.",
        "swift": "Run a Swift command or program."
    ]

    private static func phrase(for name: String, target: String?, in rules: [SummaryRule]) -> String? {
        guard let rule = rules.first(where: { $0.terms.contains(where: name.contains) }) else {
            return nil
        }
        return target.map { rule.withTarget.replacingOccurrences(of: "{target}", with: $0) } ?? rule.fallback
    }

    private static func shortTarget(_ value: String) -> String {
        let lastComponent = URL(fileURLWithPath: value).lastPathComponent
        return lastComponent.isEmpty ? value : lastComponent
    }

    private static func explain(command: String) -> String {
        let words = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard let executable = words.first else {
            return "Run a shell command."
        }
        if let line = commandSummaries[executable] {
            return line
        }
        switch executable {
        case "git":
            return "Run a Git \(words.dropFirst().first ?? "operation") operation in the repository."
        case "npm", "pnpm", "yarn":
            return "Run the \(words.dropFirst().first ?? "command") task with \(executable)."
        default:
            return "Run a shell command using \(executable)."
        }
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
