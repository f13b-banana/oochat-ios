import Foundation
import ConnectOnionKit
import XCTest
@testable import OOChatIOS

final class MockHostedAgentTests: XCTestCase {
    private let endpointA = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let endpointB = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private struct MockHostedAgent {
        let replyText: String

        func reply(to prompt: String) -> ChatMessage {
            ChatMessage(role: .agent, content: "Mock reply to '\(prompt)': \(replyText)")
        }
    }

    func testMockAgentReplyCreatesAgentMessage() {
        let agent = MockHostedAgent(replyText: "hello from test")

        let message = agent.reply(to: "ping")

        XCTAssertEqual(message.role, .agent)
        XCTAssertTrue(message.content.contains("ping"))
        XCTAssertTrue(message.content.contains("hello from test"))
        XCTAssertFalse(message.id.isEmpty)
    }

    func testNewConversationStartsEmpty() {
        let conversation = Conversation()

        XCTAssertFalse(conversation.id.isEmpty)
        XCTAssertTrue(conversation.messages.isEmpty)
    }
    func testToolCallFramesMapToCorrelatedCallAndResultEvents() {
        let arguments: [String: JSONValue] = [
            "path": .string("OOChatIOS/Features/Chat/MessageBubble.swift"),
            "line_end": .number(280)
        ]

        let call = HostedAgentEvent.from([
            "type": .string("tool_call"),
            "tool_id": .string("tool-read-1"),
            "name": .string("read_file"),
            "args": .object(arguments)
        ])
        let result = HostedAgentEvent.from([
            "type": .string("tool_result"),
            "tool_id": .string("tool-read-1"),
            "name": .string("read_file"),
            "result": .string("import SwiftUI")
        ])

        XCTAssertEqual(
            call,
            .toolCall(id: "tool-read-1", name: "read_file", arguments: arguments)
        )
        XCTAssertEqual(
            result,
            .toolResult(
                id: "tool-read-1",
                name: "read_file",
                output: "import SwiftUI",
                state: .completed
            )
        )
    }

    func testLargeToolArgumentDoesNotTrapWhenRendered() {
        let arguments: [String: JSONValue] = [
            "n": .number(1e20)
        ]

        XCTAssertEqual(ToolActionSummary.argumentsDescription(arguments), "n: 1e+20")
        XCTAssertEqual(CanonicalJSON.string(from: .number(1e20)), "1e+20")
    }

    func testChatTimelineGroupsOnlyConsecutiveToolCalls() {
        let firstTool = ChatMessage(
            id: "tool-read",
            role: .tool,
            content: "contents",
            toolName: "read_file",
            toolState: .completed
        )
        let secondTool = ChatMessage(
            id: "tool-edit",
            role: .tool,
            content: "updated",
            toolName: "edit_file",
            toolState: .completed
        )
        let reply = ChatMessage(id: "reply", role: .agent, content: "Done")
        let finalTool = ChatMessage(
            id: "tool-command",
            role: .tool,
            content: "success",
            toolName: "exec_command",
            toolState: .completed
        )

        let entries = ChatTimelineBuilder.entries(
            from: [firstTool, secondTool, reply, finalTool]
        )

        XCTAssertEqual(entries.count, 3)
        guard case .toolCallGroup(let groupedTools) = entries[0] else {
            return XCTFail("Expected consecutive tool calls to be grouped")
        }
        XCTAssertEqual(groupedTools.map(\.id), ["tool-read", "tool-edit"])
        XCTAssertEqual(entries[1], .message(reply))
        XCTAssertEqual(entries[2], .message(finalTool))
    }

    func testToolCallGroupSummaryCombinesActionCategories() {
        let messages = [
            ChatMessage(role: .tool, content: "", toolName: "edit_file", toolState: .completed),
            ChatMessage(role: .tool, content: "", toolName: "read_file", toolState: .completed),
            ChatMessage(role: .tool, content: "", toolName: "exec_command", toolState: .completed)
        ]

        XCTAssertEqual(
            ToolCallGroupSummary.title(for: messages),
            "Edited a file, read a file, and ran a command"
        )
    }

    func testCanonicalJSONMatchesPythonUnicodeEscaping() {
        let value: JSONValue = .object([
            "prompt": .string("执行 tree café 🧅")
        ])

        XCTAssertEqual(
            CanonicalJSON.string(from: value),
            #"{"prompt":"\u6267\u884c tree caf\u00e9 \ud83e\uddc5"}"#
        )
    }

    func testToolResultUsesErrorStateAndMessageFallback() {
        let event = HostedAgentEvent.from([
            "type": .string("tool_result"),
            "id": .string("tool-shell-1"),
            "status": .string("error"),
            "message": .string("Permission denied")
        ])

        XCTAssertEqual(
            event,
            .toolResult(
                id: "tool-shell-1",
                name: nil,
                output: "Permission denied",
                state: .failed
            )
        )
    }

    func testToolResultPreservesStructuredOutput() {
        let event = HostedAgentEvent.from([
            "type": .string("tool_result"),
            "tool_id": .string("tool-search-1"),
            "result": .object([
                "files": .array([.string("README.md")])
            ])
        ])

        guard case .toolResult(_, _, let output, _) = event else {
            return XCTFail("Expected a tool result event")
        }
        XCTAssertTrue(output.contains("files"))
        XCTAssertTrue(output.contains("README.md"))
    }

    func testToolEventParserIgnoresFramesWithoutCallIdentifiers() {
        XCTAssertNil(HostedAgentEvent.from([
            "type": .string("tool_call"),
            "name": .string("read_file")
        ]))
    }

    func testModeChangedFrameMapsToModeEvent() {
        XCTAssertEqual(
            HostedAgentEvent.from([
                "type": .string("mode_changed"),
                "mode": .string("auto"),
                "turns_left": .null
            ]),
            .modeChanged(mode: .auto, turnsLeft: nil)
        )
    }

    func testApprovalFrameMapsToRequest() {
        let request = ToolApprovalRequest.from([
            "type": .string("approval_needed"),
            "approval_id": .string("approval-1"),
            "tool": .string("write"),
            "arguments": .object([
                "path": .string("prompt.md"),
                "content": .string("You are a summarizer.")
            ]),
            "description": .string("Create the agent prompt"),
            "batch_remaining": .array([
                .object([
                    "tool": .string("bash"),
                    "arguments": .string(#"{"command":"swift test"}"#)
                ]),
                .object([
                    "tool": .string("notify"),
                    "arguments": .string("not-json")
                ])
            ])
        ])

        XCTAssertEqual(
            request,
            ToolApprovalRequest(
                id: "approval-1",
                tool: "write",
                arguments: [
                    "path": .string("prompt.md"),
                    "content": .string("You are a summarizer.")
                ],
                description: "Create the agent prompt",
                batchRemaining: [
                    ToolApprovalBatchItem(
                        tool: "bash",
                        arguments: ["command": .string("swift test")]
                    ),
                    ToolApprovalBatchItem(
                        tool: "notify",
                        rawArguments: .string("not-json")
                    )
                ]
            )
        )
    }

    func testApprovalFrameAcceptsArgsAliasAndCreatesLocalIdentifier() {
        let request = ToolApprovalRequest.from([
            "type": .string("APPROVAL_NEEDED"),
            "tool": .string("edit"),
            "args": .object(["path": .string("README.md")])
        ])

        XCTAssertEqual(request?.tool, "edit")
        XCTAssertEqual(request?.arguments, ["path": .string("README.md")])
        XCTAssertFalse(request?.id.isEmpty ?? true)
    }

    func testApprovalFrameRejectsMissingTool() {
        XCTAssertNil(ToolApprovalRequest.from([
            "type": .string("approval_needed"),
            "arguments": .object([:])
        ]))
    }

    func testApprovalFrameDecodesStringEncodedArguments() {
        let request = ToolApprovalRequest.from([
            "type": .string("approval_needed"),
            "tool": .string("write"),
            "arguments": .string("{\"path\":\"prompt.md\"}")
        ])
        XCTAssertEqual(request?.arguments, ["path": .string("prompt.md")])
    }

    /// Arguments the server sends in a shape we cannot interpret must still produce a card —
    /// failing the frame costs the user the entire round-trip.
    func testApprovalFramePreservesUndecodableArguments() {
        let request = ToolApprovalRequest.from([
            "type": .string("approval_needed"),
            "tool": .string("write"),
            "arguments": .string("prompt.md")
        ])
        XCTAssertEqual(request?.arguments, ["value": .string("prompt.md")])
    }

    func testApprovalDecisionsEncodeTheirFields() {
        XCTAssertEqual(
            ApprovalDecision.allowOnce.decisionFields,
            [
                "approved": .bool(true),
                "scope": .string("once")
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.allowSession.decisionFields,
            [
                "approved": .bool(true),
                "scope": .string("session")
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.rejectSoft(feedback: "Use a different file").decisionFields,
            [
                "approved": .bool(false),
                "scope": .string("once"),
                "mode": .string("reject_soft"),
                "feedback": .string("Use a different file")
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.rejectHard(feedback: nil).decisionFields,
            [
                "approved": .bool(false),
                "scope": .string("once"),
                "mode": .string("reject_hard")
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.rejectExplain(feedback: nil).decisionFields,
            [
                "approved": .bool(false),
                "scope": .string("once"),
                "mode": .string("reject_explain")
            ]
        )
    }

    /// `Int(Double)` traps on out-of-range values, so a hostile frame could crash the app.
    func testUlwCheckpointFrameRejectsOutOfRangeTurnCounts() {
        XCTAssertNil(UlwCheckpointRequest.from([
            "type": .string("ulw_turns_reached"),
            "turns_used": .number(1e300),
            "max_turns": .number(100)
        ]))
        XCTAssertNil(UlwCheckpointRequest.from([
            "type": .string("ulw_turns_reached"),
            "turns_used": .number(1),
            "max_turns": .number(.nan)
        ]))
    }

    /// The placeholder answers on the user's behalf when a payload will not parse, so it must
    /// carry the ID the frame arrived with rather than inventing one.
    func testDeclinePlaceholderPreservesFrameIdentifier() {
        let approval = HostedAgentInteraction.declinePlaceholder(for: [
            "type": .string("approval_needed"),
            "approval_id": .string("ap-7")
        ])
        XCTAssertEqual(approval?.id, "ap-7")

        let plan = HostedAgentInteraction.declinePlaceholder(for: [
            "type": .string("plan_review"),
            "id": .string("plan-3")
        ])
        XCTAssertEqual(plan?.id, "plan-3")

        XCTAssertNil(HostedAgentInteraction.declinePlaceholder(for: [
            "type": .string("something_else")
        ]))
    }

    /// `contains("10.")` used to match `x.example.com:8010.` and miss most of 172.16/12.
    func testPrivateHostClassificationCoversRFC1918AndIPv6() {
        XCTAssertTrue(HostedAgentDiscovery.isPrivateIPv4("10.0.0.4"))
        XCTAssertTrue(HostedAgentDiscovery.isPrivateIPv4("172.16.0.1"))
        XCTAssertTrue(HostedAgentDiscovery.isPrivateIPv4("172.31.255.254"))
        XCTAssertTrue(HostedAgentDiscovery.isPrivateIPv4("192.168.1.10"))

        XCTAssertFalse(HostedAgentDiscovery.isPrivateIPv4("172.15.0.1"))
        XCTAssertFalse(HostedAgentDiscovery.isPrivateIPv4("172.32.0.1"))
        XCTAssertFalse(HostedAgentDiscovery.isPrivateIPv4("192.169.1.10"))
        XCTAssertFalse(HostedAgentDiscovery.isPrivateIPv4("x.example.com"))
        XCTAssertFalse(HostedAgentDiscovery.isPrivateIPv4("8.8.8.8"))

        XCTAssertTrue(HostedAgentDiscovery.isPrivateHost("fe80::1"))
        XCTAssertTrue(HostedAgentDiscovery.isPrivateHost("[fd00::1234]"))
        XCTAssertFalse(HostedAgentDiscovery.isPrivateHost("2001:4860:4860::8888"))
    }

    func testUlwCheckpointFramesMatchUpstreamContract() {
        let request = UlwCheckpointRequest.from([
            "type": .string("ulw_turns_reached"),
            "turns_used": .number(100),
            "max_turns": .number(100)
        ])
        XCTAssertEqual(request?.turnsUsed, 100)
        XCTAssertEqual(request?.maxTurns, 100)

        XCTAssertEqual(
            UlwCheckpointDecision.continueWork(turns: 100).responseFrame,
            [
                "type": .string("ULW_RESPONSE"),
                "action": .string("continue"),
                "turns": .number(100)
            ]
        )
        XCTAssertEqual(
            UlwCheckpointDecision.switchMode(.accept).responseFrame,
            [
                "type": .string("ULW_RESPONSE"),
                "action": .string("switch_mode"),
                "mode": .string("accept_edits")
            ]
        )
    }

    func testPlanReviewFramesMatchUpstreamContract() {
        let request = PlanReviewRequest.from([
            "type": .string("plan_review"),
            "plan_content": .string("# Plan\n\n1. Implement")
        ])
        XCTAssertEqual(request?.planContent, "# Plan\n\n1. Implement")

        XCTAssertEqual(
            PlanReviewDecision.approve.responseFrame(for: request!),
            [
                "type": .string("PLAN_REVIEW_RESPONSE"),
                "message": .string("Plan approved. Implement now. Do NOT re-enter plan mode.\n\n---\n\n# Plan\n\n1. Implement")
            ]
        )
        XCTAssertEqual(
            PlanReviewDecision.requestChanges(feedback: "Use smaller commits").responseFrame(for: request!),
            [
                "type": .string("PLAN_REVIEW_RESPONSE"),
                "message": .string("Plan rejected. Revise with write_plan(). Feedback: Use smaller commits")
            ]
        )
    }

    func testAskUserFrameMapsAllSupportedInputShapes() {
        let request = AskUserRequest.from([
            "type": .string("ask_user"),
            "id": .string("question-1"),
            "question": .string("Enter your login"),
            "options": .array([.string("Use saved account")]),
            "multi_select": .bool(true),
            "fields": .array([
                .object([
                    "name": .string("username"),
                    "label": .string("Username"),
                    "type": .string("text"),
                    "placeholder": .string("name@example.com")
                ]),
                .object([
                    "name": .string("password"),
                    "label": .string("Password"),
                    "type": .string("password")
                ])
            ])
        ])

        XCTAssertEqual(
            request,
            AskUserRequest(
                id: "question-1",
                question: "Enter your login",
                options: ["Use saved account"],
                multiSelect: true,
                fields: [
                    AskUserField(
                        name: "username",
                        label: "Username",
                        placeholder: "name@example.com"
                    ),
                    AskUserField(name: "password", label: "Password", type: "password")
                ]
            )
        )
        XCTAssertTrue(request?.fields.last?.isSecure ?? false)
    }

    func testAskUserFrameAcceptsLegacyTextAndDefaultsOptionalValues() {
        let request = AskUserRequest.from([
            "type": .string("ask_user"),
            "text": .string("Which date?")
        ])

        XCTAssertEqual(request?.question, "Which date?")
        XCTAssertEqual(request?.options, [])
        XCTAssertEqual(request?.fields, [])
        XCTAssertEqual(request?.multiSelect, false)
        XCTAssertFalse(request?.id.isEmpty ?? true)
    }

    func testAskUserRejectsMissingQuestion() {
        XCTAssertNil(AskUserRequest.from([
            "type": .string("ask_user"),
            "options": .array([.string("Yes")])
        ]))
    }

    @MainActor
    func testSaveAgentUpdatesEndpointAndClearsSessions() {
        let viewModel = makeViewModel()
        let agent = viewModel.saveAgent(name: "Primary", address: endpointA)
        XCTAssertNotNil(agent)
        let conversation = viewModel.createConversation(for: agent!)
        viewModel.selectConversation(conversation)
        var seeded = conversation
        seeded.serverSession = ["session_id": .string(conversation.id)]
        viewModel.upsertForTesting(seeded)
        XCTAssertNotNil(viewModel.conversations.first { $0.id == conversation.id }?.serverSession)

        let updated = viewModel.saveAgent(id: agent!.id, name: "Renamed", address: endpointB)

        XCTAssertEqual(updated?.id, agent?.id)
        XCTAssertEqual(updated?.name, "Renamed")
        XCTAssertEqual(updated?.address, endpointB)
        XCTAssertEqual(viewModel.conversations.first?.agentID, agent?.id)
        XCTAssertEqual(viewModel.conversations.first?.agentAddress, endpointB)
        XCTAssertNil(viewModel.conversations.first?.serverSession)
    }

    @MainActor
    func testDuplicateEndpointsRemainDistinctConfigurations() {
        let viewModel = makeViewModel()

        let first = viewModel.saveAgent(name: "First", address: endpointA)
        let second = viewModel.saveAgent(name: "Second", address: endpointA)

        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(viewModel.agents.count, 2)
        XCTAssertEqual(Set(viewModel.agents.map(\.name)), ["First", "Second"])
    }

    @MainActor
    func testDeletingAgentRemovesAgentAndConversations() {
        let viewModel = makeViewModel()
        let first = viewModel.saveAgent(name: "First", address: endpointA)!
        let second = viewModel.saveAgent(name: "Second", address: endpointB)!
        let deletedConversation = viewModel.createConversation(for: first)
        let remainingConversation = viewModel.createConversation(for: second)

        viewModel.deleteAgent(first)

        XCTAssertFalse(viewModel.agents.contains { $0.id == first.id })
        XCTAssertFalse(viewModel.conversations.contains { $0.id == deletedConversation.id })
        XCTAssertTrue(viewModel.conversations.contains { $0.id == remainingConversation.id })
        XCTAssertEqual(viewModel.activeAgentID, second.id)
    }

    @MainActor
    func testSwitchToAgentForChatCreatesConversationWhenMissing() {
        let viewModel = makeViewModel()
        let agent = viewModel.saveAgent(name: "Primary", address: endpointA)!

        viewModel.switchToAgentForChat(agent)

        XCTAssertEqual(viewModel.activeAgentID, agent.id)
        XCTAssertEqual(viewModel.activeConversation?.agentID, agent.id)
        XCTAssertEqual(viewModel.activeConversation?.agentAddress, endpointA)
    }

    func testModeChangedFramesParseTurnsLeft() throws {
        XCTAssertEqual(
            HostedAgentEvent.from(try KitFixtures.frame("mode_changed.full_access")),
            .modeChanged(mode: .fullAccess, turnsLeft: 5)
        )
        XCTAssertEqual(
            HostedAgentEvent.from(try KitFixtures.frame("mode_changed")),
            .modeChanged(mode: .auto, turnsLeft: nil)
        )
    }

    func testChatModesMapToOIPModesAsMacOSDoes() {
        for mode in ChatMode.offered {
            XCTAssertEqual(ChatMode(permissionMode: mode.oipPermissionMode), mode)
        }
        XCTAssertEqual(ChatMode.plan.oipPermissionMode, .readOnly)
        XCTAssertEqual(ChatMode.safe.oipPermissionMode, .auto)
        XCTAssertEqual(ChatMode.ulw.oipPermissionMode, .fullAccess)
        XCTAssertEqual(ChatMode.accept.oipPermissionMode, .auto)
    }

    @MainActor
    func testSetModeIsPendingUntilTheHostAnswers() async throws {
        for reply in [
            nil,
            HostedAgentEvent.modeChangeTimedOut,
            .modeChangeFailed("Mode not offered")
        ] {
            let (viewModel, transport) = try makeModeEnvironment()
            transport.modeChangeReply = reply

            viewModel.setMode(.plan)
            XCTAssertEqual(viewModel.activePendingMode, .plan)
            XCTAssertEqual(viewModel.activeMode, .safe)
            await viewModel.settleModeChange()

            XCTAssertNil(viewModel.activePendingMode)
            XCTAssertEqual(viewModel.activeMode, reply == nil ? .plan : .safe)
            XCTAssertEqual(viewModel.errorMessage != nil, reply != nil)
        }

        let (viewModel, transport) = try makeModeEnvironment()
        transport.modeChangeError = HostedAgentClientError.closed
        viewModel.setMode(.plan)
        await viewModel.settleModeChange()
        XCTAssertNil(viewModel.activePendingMode)
        XCTAssertEqual(viewModel.activeMode, .safe)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    @MainActor
    func testTurnsLeftOnlyShowsInFullAccess() async throws {
        let (viewModel, transport) = try makeModeEnvironment()
        transport.modeChangeReply = .modeChanged(mode: .fullAccess, turnsLeft: 5)
        viewModel.setMode(.ulw)
        await viewModel.settleModeChange()
        XCTAssertEqual(viewModel.activeFullAccessTurnsLeft, 5)

        transport.modeChangeReply = .modeChanged(mode: .auto, turnsLeft: 5)
        viewModel.setMode(.safe)
        await viewModel.settleModeChange()
        XCTAssertNil(viewModel.activeFullAccessTurnsLeft)
    }

    @MainActor
    func testFullAccessIsOfferedOnlyOnceConnectedListsIt() async throws {
        let (viewModel, transport) = try makeModeEnvironment()
        XCTAssertEqual(viewModel.offeredModes, [.plan, .safe])

        viewModel.agentAddressDraft = endpointA
        transport.connectSessionModes = try KitFixtures.sessionModes("CONNECTED.new", folder: "handshake")
        _ = await viewModel.connectToAgent()
        XCTAssertEqual(viewModel.offeredModes, [.plan, .safe])

        transport.connectSessionModes = try KitFixtures.sessionModes("CONNECTED")
        _ = await viewModel.connectToAgent()
        XCTAssertEqual(viewModel.offeredModes, [.plan, .safe, .ulw])
    }

    @MainActor
    private func makeModeEnvironment() throws -> (ChatViewModel, MockAgentTransport) {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        let transport = MockAgentTransport()
        let viewModel = ChatViewModel(store: store, client: transport, networkMonitor: MockNetworkMonitor())
        let agent = viewModel.saveAgent(name: "Modes", address: endpointA)!
        _ = viewModel.createConversation(for: agent)
        return (viewModel, transport)
    }

    @MainActor
    private func makeViewModel() -> ChatViewModel {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = try! SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        return ChatViewModel(store: store)
    }
}
