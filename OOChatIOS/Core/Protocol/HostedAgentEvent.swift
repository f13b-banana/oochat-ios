import Foundation
import ConnectOnionKit

enum HostedAgentEvent: Equatable {
    case toolCall(id: String, name: String, arguments: [String: JSONValue])
    case toolResult(id: String, name: String?, output: String, state: ToolCallState)

    case modeChanged(mode: OIPPermissionMode, turnsLeft: Int?)
    case modeChangeFailed(String)
    case modeChangeTimedOut

    static func from(_ frame: [String: JSONValue]) -> HostedAgentEvent? {
        guard let type = frame["type"]?.stringValue else {
            return nil
        }

        if type == "mode_changed",
            let rawMode = frame["mode"]?.stringValue {
            return .modeChanged(
                mode: OIPPermissionMode(protocolValue: rawMode),
                turnsLeft: frame["turns_left"]?.intValue
            )
        }

        guard let id = frame["tool_id"]?.stringValue ?? frame["id"]?.stringValue,
              !id.isEmpty else {
            return nil
        }

        switch type {
        case "tool_call":
            let name = frame["name"]?.stringValue ?? "tool"
            let arguments: [String: JSONValue]
            if case .object(let value)? = frame["args"] {
                arguments = value
            } else {
                arguments = [:]
            }
            return .toolCall(id: id, name: name, arguments: arguments)
        case "tool_result":
            let state: ToolCallState = frame["status"]?.stringValue?.lowercased() == "error" ? .failed : .completed
            return .toolResult(
                id: id,
                name: frame["name"]?.stringValue,
                output: messageText(frame),
                state: state
            )
        default:
            return nil
        }
    }

    static func messageText(_ frame: [String: JSONValue]) -> String {
        for key in ["result", "message", "error", "text", "content"] {
            if let value = frame[key] {
                if let text = value.stringValue {
                    return text
                }
                return formattedJSON(value)
            }
        }
        return "Hosted agent returned \(frame["type"]?.stringValue ?? "an event")."
    }

    private static func formattedJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
