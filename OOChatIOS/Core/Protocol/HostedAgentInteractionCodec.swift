import Foundation
import ConnectOnionKit

extension ToolApprovalRequest {
    static func from(_ frame: [String: JSONValue]) -> ToolApprovalRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "approval_needed",
              let tool = frame["tool"]?.stringValue,
              !tool.isEmpty else {
            return nil
        }

        // Accept both object and JSON-string arguments from older servers.
        let arguments: [String: JSONValue]
        switch decodedArguments(frame["arguments"] ?? frame["args"] ?? .object([:])) {
        case .object(let value):
            arguments = value
        case .null:
            arguments = [:]
        case let other:
            arguments = ["value": other]
        }

        let identifier = frame["approval_id"]?.stringValue
            ?? frame["request_id"]?.stringValue
            ?? frame["id"]?.stringValue
            ?? UUID().uuidString
        let batchRemaining = batchItems(from: frame["batch_remaining"])

        return ToolApprovalRequest(
            id: identifier,
            tool: tool,
            arguments: arguments,
            description: frame["description"]?.stringValue,
            batchRemaining: batchRemaining
        )
    }

    private static func batchItems(from value: JSONValue?) -> [ToolApprovalBatchItem] {
        guard case .array(let values)? = value else {
            return []
        }
        return values.compactMap { item in
            guard case .object(let object) = item,
                  let tool = object["tool"]?.stringValue,
                  !tool.isEmpty else {
                return nil
            }
            let rawArguments = object["arguments"] ?? object["args"] ?? .object([:])
            return ToolApprovalBatchItem(
                tool: tool,
                rawArguments: decodedArguments(rawArguments)
            )
        }
    }

    private static func decodedArguments(_ value: JSONValue) -> JSONValue {
        guard case .string(let text) = value,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return value
        }
        return decoded
    }
}

extension ApprovalDecision {
    var responseFrame: [String: JSONValue] {
        responseFrame(to: nil)
    }

    func responseFrame(to recipient: String?) -> [String: JSONValue] {
        var frame: [String: JSONValue] = [
            "type": .string("APPROVAL_RESPONSE"),
            "scope": .string("once")
        ]

        switch self {
        case .allowOnce:
            frame["approved"] = .bool(true)
        case .allowSession:
            frame["approved"] = .bool(true)
            frame["scope"] = .string("session")
        case .rejectSoft(let feedback):
            frame["approved"] = .bool(false)
            frame["mode"] = .string("reject_soft")
            if let feedback, !feedback.isEmpty {
                frame["feedback"] = .string(feedback)
            }
        case .rejectHard(let feedback):
            frame["approved"] = .bool(false)
            frame["mode"] = .string("reject_hard")
            if let feedback, !feedback.isEmpty {
                frame["feedback"] = .string(feedback)
            }
        case .rejectExplain(let feedback):
            frame["approved"] = .bool(false)
            frame["mode"] = .string("reject_explain")
            if let feedback, !feedback.isEmpty {
                frame["feedback"] = .string(feedback)
            }
        }

        if let recipient, !recipient.isEmpty {
            frame["to"] = .string(recipient)
        }

        return frame
    }
}

extension UlwCheckpointRequest {
    static func from(_ frame: [String: JSONValue]) -> UlwCheckpointRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "ulw_turns_reached",
              let turnsUsed = frame["turns_used"]?.numberValue,
              let maxTurns = frame["max_turns"]?.numberValue,
              // Reject numbers outside the range supported by Int.
              let turnsUsedInt = Int(exactly: turnsUsed.rounded()),
              let maxTurnsInt = Int(exactly: maxTurns.rounded()) else {
            return nil
        }
        return UlwCheckpointRequest(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            turnsUsed: turnsUsedInt,
            maxTurns: maxTurnsInt
        )
    }
}

extension UlwCheckpointDecision {
    var responseFrame: [String: JSONValue] {
        switch self {
        case .continueWork(let turns):
            return [
                "type": .string("ULW_RESPONSE"),
                "action": .string("continue"),
                "turns": .number(Double(turns))
            ]
        case .switchMode(let mode):
            return [
                "type": .string("ULW_RESPONSE"),
                "action": .string("switch_mode"),
                "mode": .string(mode.rawValue)
            ]
        }
    }
}

extension PlanReviewRequest {
    static func from(_ frame: [String: JSONValue]) -> PlanReviewRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "plan_review",
              let content = frame["plan_content"]?.stringValue,
              !content.isEmpty else {
            return nil
        }
        return PlanReviewRequest(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            planContent: content
        )
    }
}

extension PlanReviewDecision {
    func responseFrame(for request: PlanReviewRequest) -> [String: JSONValue] {
        let message: String
        switch self {
        case .approve:
            message = "Plan approved. Implement now. Do NOT re-enter plan mode.\n\n---\n\n\(request.planContent)"
        case .requestChanges(let feedback):
            let trimmed = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = trimmed.isEmpty ? "Plan needs revision." : trimmed
            message = "Plan rejected. Revise with write_plan(). Feedback: \(detail)"
        }
        return [
            "type": .string("PLAN_REVIEW_RESPONSE"),
            "message": .string(message)
        ]
    }
}

extension AskUserRequest {
    static func from(_ frame: [String: JSONValue]) -> AskUserRequest? {
        guard frame["type"]?.stringValue?.lowercased() == "ask_user",
              let question = frame["question"]?.stringValue ?? frame["text"]?.stringValue,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let options: [String]
        if case .array(let values)? = frame["options"] {
            options = values.compactMap(\.stringValue)
        } else {
            options = []
        }

        let fields: [AskUserField]
        if case .array(let values)? = frame["fields"] {
            var seenNames: Set<String> = []
            fields = values.compactMap { value in
                guard case .object(let field) = value,
                      let name = field["name"]?.stringValue,
                      !name.isEmpty,
                      seenNames.insert(name).inserted else {
                    return nil
                }
                return AskUserField(
                    name: name,
                    label: field["label"]?.stringValue ?? name,
                    type: field["type"]?.stringValue ?? "text",
                    placeholder: field["placeholder"]?.stringValue
                )
            }
        } else {
            fields = []
        }

        let multiSelect: Bool
        if case .bool(let value)? = frame["multi_select"] {
            multiSelect = value
        } else {
            multiSelect = false
        }

        return AskUserRequest(
            id: frame["id"]?.stringValue ?? UUID().uuidString,
            question: question,
            options: options,
            multiSelect: multiSelect,
            fields: fields
        )
    }
}

extension HostedAgentInteraction {
    static func from(_ frame: [String: JSONValue]) -> HostedAgentInteraction? {
        switch frame["type"]?.stringValue?.lowercased() {
        case "approval_needed":
            return ToolApprovalRequest.from(frame).map(Self.approval)
        case "ulw_turns_reached":
            return UlwCheckpointRequest.from(frame).map(Self.ulwCheckpoint)
        case "plan_review":
            return PlanReviewRequest.from(frame).map(Self.planReview)
        case "ask_user":
            return AskUserRequest.from(frame).map(Self.askUser)
        default:
            return nil
        }
    }

    /// Keeps the interaction kind and ID when its payload cannot be decoded.
    static func declinePlaceholder(for frame: [String: JSONValue]) -> HostedAgentInteraction? {
        let identifier = frame["approval_id"]?.stringValue
            ?? frame["request_id"]?.stringValue
            ?? frame["id"]?.stringValue
            ?? UUID().uuidString
        switch frame["type"]?.stringValue?.lowercased() {
        case "approval_needed":
            return .approval(ToolApprovalRequest(id: identifier, tool: "unknown", arguments: [:]))
        case "ulw_turns_reached":
            return .ulwCheckpoint(UlwCheckpointRequest(id: identifier, turnsUsed: 0, maxTurns: 0))
        case "plan_review":
            return .planReview(PlanReviewRequest(id: identifier, planContent: ""))
        case "ask_user":
            return .askUser(AskUserRequest(id: identifier, question: ""))
        default:
            return nil
        }
    }

    var unavailableDecision: HostedAgentInteractionDecision {
        switch self {
        case .approval:
            return .approval(.rejectHard(feedback: "Approval unavailable."))
        case .ulwCheckpoint:
            return .ulwCheckpoint(.switchMode(.safe))
        case .planReview:
            return .planReview(.requestChanges(feedback: "Plan review unavailable."))
        case .askUser:
            return .askUser(.cancel)
        }
    }
}
