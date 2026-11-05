import Foundation

/// What the composer text means for EXEC.
public enum OIPExecCommandParse: Equatable, Sendable {
    /// Ordinary text. Send it to the agent as a prompt.
    case notACommand
    /// `/exec <tool> [name=value ...]`. Run the tool on the host, bypass LLM.
    case command(OIPExecCommand)
    /// Starts with `/exec` but cannot be run. Reason denoted by shown text.
    case invalid(String)
}

/// A typed `/exec` command
/// Every value is a string;  host hands it to the tool as typed.
public struct OIPExecCommand: Equatable, Sendable {
    public static let prefix = "/exec"
    public static let usage = "Usage: /exec <tool> [name=value ...]. Quote a value with spaces: command=\"ls -la\"."

    public let tool: String
    public let args: [String: JSONValue]

    public init(tool: String, args: [String: JSONValue] = [:]) {
        self.tool = tool
        self.args = args
    }

    /// The arguments as `name=value` pairs in name order.
    public var argumentSummary: String {
        args.keys.sorted()
            .map { "\($0)=\(args[$0]?.stringValue ?? "")" }
            .joined(separator: " ")
    }

    public static func parse(_ text: String) -> OIPExecCommandParse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            return .notACommand
        }
        let rest = String(trimmed.dropFirst(prefix.count))
        // "/execute the plan" is ordinary text, not a misspelt command.
        guard rest.isEmpty || rest.first?.isWhitespace == true else {
            return .notACommand
        }
        guard let words = splitWords(rest) else {
            return .invalid("Close the quote. \(usage)")
        }
        guard let tool = words.first else {
            return .invalid(usage)
        }
        guard !tool.contains("=") else {
            return .invalid("Name the tool first, then its arguments. \(usage)")
        }
        let parsed = arguments(from: Array(words.dropFirst()))
        if let badWord = parsed.badWord {
            return .invalid("\"\(badWord)\" is not name=value. \(usage)")
        }
        return .command(OIPExecCommand(tool: tool, args: parsed.args))
    }

    /// Splits on spaces. Single or double quotes keep a value together..
    /// Dropped with nil when a quote is never closed.
    private static func splitWords(_ text: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var quote: Character?
        for character in text {
            // `quote` denotes if inside quotes (nil if outside)
            // `open` holds the opening character
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord {
                    words.append(current)
                    current = ""
                    hasWord = false
                }
            } else {
                current.append(character)
                hasWord = true
            }
        }
        guard quote == nil else {
            return nil
        }
        if hasWord {
            words.append(current)
        }
        return words
    }

    private static func arguments(from words: [String]) -> (args: [String: JSONValue], badWord: String?) {
        var args: [String: JSONValue] = [:]
        for word in words {
            let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else {
                return ([:], word)
            }
            args[String(parts[0])] = .string(String(parts[1]))
        }
        return (args, nil)
    }
}

extension OIPExecResult {
    /// The most text one result shows.
    public static let displayLimit = 4_000

    /// Show tool's output when if ran; show the host's reason if not ran.
    /// Any status other than "success" is  a failure
    public var displayText: String {
        let text = (isSuccess ? result : (error ?? result)) ?? ""
        guard !text.isEmpty else {
            return isSuccess ? "(no output)" : "The agent reported \"\(status)\" without saying why."
        }
        guard text.count > Self.displayLimit else {
            return text
        }
        let hidden = text.count - Self.displayLimit
        return String(text.prefix(Self.displayLimit)) + "\n... \(hidden) more characters not shown"
    }
}
