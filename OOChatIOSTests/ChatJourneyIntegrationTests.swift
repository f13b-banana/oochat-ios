import XCTest
import ConnectOnionKit
@testable import OOChatIOS

// end to end integration tests for chat
@MainActor
final class ChatJourneyIntegrationTests: XCTestCase {
    private static let address = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    // prompt → tool call → approval card → approved → agent reply, then a relaunch
    func testToolCallAndApprovalJourneySurvivesRelaunch() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()

        let agent = try XCTUnwrap(
            viewModel.saveAgent(name: "Release Bot", address: Self.address)
        )
        let conversation = viewModel.createConversation(for: agent)

        app.transport.approvalRequests = [
            ToolApprovalRequest(
                id: "approval-1",
                tool: "write_file",
                arguments: ["path": .string("RELEASE.md")]
            )
        ]
        app.transport.streamedEvents = [
            .toolCall(id: "tool-1", name: "write_file", arguments: ["path": .string("RELEASE.md")]),
            .toolResult(id: "tool-1", name: "write_file", output: "Wrote RELEASE.md", state: .completed)
        ]
        app.transport.sendBehavior = .succeed(output: "Release notes are ready.")

        viewModel.prompt = "Draft the release notes"
        viewModel.sendPrompt()

        await waitForPendingApproval(on: viewModel)
        XCTAssertEqual(viewModel.activePendingApproval?.conversationID, conversation.id)
        XCTAssertEqual(viewModel.activePendingApproval?.request.tool, "write_file")
        XCTAssertTrue(viewModel.isProcessing)

        viewModel.allowPendingApprovalOnce(id: try XCTUnwrap(viewModel.activePendingApproval).id)
        await viewModel.sendTask?.value

        XCTAssertEqual(app.transport.approvalDecisions, [.allowOnce])
        XCTAssertEqual(app.transport.sentPrompts, ["Draft the release notes"])
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.connectionState, .connected)
        assertReleaseNotesTimeline(viewModel.activeConversation, when: "before relaunch")

        viewModel = try app.relaunch()

        XCTAssertEqual(viewModel.agents.map(\.address), [Self.address])
        XCTAssertEqual(viewModel.agents.first?.name, "Release Bot")
        XCTAssertEqual(viewModel.activeAgentID, agent.id)
        XCTAssertEqual(viewModel.activeConversationID, conversation.id)
        assertReleaseNotesTimeline(viewModel.activeConversation, when: "after relaunch")
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertFalse(viewModel.isProcessing)
    }

    // Typing while offline must not cost the user their message.
    func testPromptQueuedWhileOfflineSurvivesRelaunchAndSendsOnce() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()

        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Ops", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)

        app.monitor.simulate(online: false)
        viewModel.prompt = "Restart the worker"
        viewModel.sendPrompt()

        XCTAssertTrue(viewModel.isOffline)
        XCTAssertTrue(app.transport.sentPrompts.isEmpty)
        XCTAssertEqual(viewModel.activeConversation?.messages.map(\.deliveryState), [.queued])

        viewModel = try app.relaunch()

        let restored = try XCTUnwrap(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(restored.messages.map(\.content), ["Restart the worker"])
        XCTAssertEqual(restored.messages.map(\.deliveryState), [.queued])
        XCTAssertEqual(restored.title, "Restart the worker")
        XCTAssertTrue(app.transport.sentPrompts.isEmpty)

        app.transport.sendBehavior = .succeed(output: "Worker restarted.")
        app.monitor.simulate(online: true)
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(app.transport.sentPrompts, ["Restart the worker"])
        let delivered = try XCTUnwrap(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(delivered.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(delivered.messages.map(\.deliveryState), [.sent, .sent])
        XCTAssertEqual(delivered.messages.last?.content, "Worker restarted.")

        viewModel = try app.relaunch()

        let reloaded = try XCTUnwrap(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(reloaded.messages.map(\.content), ["Restart the worker", "Worker restarted."])
        XCTAssertFalse(reloaded.messages.contains { $0.deliveryState == .queued })
    }

    // The reported bug: force-quit while the agent runs, relaunch, and the app sent the same
    // prompt again, so the agent ran it twice. The relaunch must ask the host, not resend.
    func testForceQuitMidRunSettlesFromHostWithoutResending() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Files", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)

        let gate = PromptGate()
        app.transport.sendBehavior = .wait(gate: gate, output: "never seen")
        viewModel.prompt = "Make him a text file"
        viewModel.sendPrompt()

        // The mark must be on disk before the reply, or a kill now would resend.
        var onDisk: MessageDeliveryState?
        for _ in 0..<200 where onDisk != .transmitted {
            await Task.yield()
            onDisk = app.snapshotFromDisk()?
                .conversations.first { $0.id == conversation.id }?
                .messages.first { $0.role == .user }?.deliveryState
        }
        XCTAssertEqual(onDisk, .transmitted)

        // "Force quit": the old process never gets its reply.
        viewModel = try app.relaunch()
        app.transport.resumeBehavior = .succeed(output: "Created smiley.txt")
        app.monitor.simulate(online: true)
        await viewModel.flushQueuedMessages()

        XCTAssertTrue(app.transport.sentPrompts.isEmpty, "the prompt was sent again")
        XCTAssertEqual(app.transport.resumedPrompts, ["Make him a text file"])
        let settled = try XCTUnwrap(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(settled.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(settled.messages.map(\.deliveryState), [.sent, .sent])
        XCTAssertEqual(settled.messages.last?.content, "Created smiley.txt")
        // Release the old process's stalled send only now, so it cannot race the relaunch.
        await gate.open()
    }

    // If the host has no record of the turn, the app must not guess: the message fails
    // with a Retry button and nothing is sent.
    func testRelaunchWithUnknownOutcomeFailsInsteadOfResending() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Files", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)

        let gate = PromptGate()
        app.transport.sendBehavior = .wait(gate: gate, output: "never seen")
        viewModel.prompt = "Delete the temp folder"
        viewModel.sendPrompt()
        var onDisk: MessageDeliveryState?
        for _ in 0..<200 where onDisk != .transmitted {
            await Task.yield()
            onDisk = app.snapshotFromDisk()?
                .conversations.first { $0.id == conversation.id }?
                .messages.first { $0.role == .user }?.deliveryState
        }
        XCTAssertEqual(onDisk, .transmitted)

        viewModel = try app.relaunch()
        // MockAgentTransport's default resumeBehavior is .fail(.outcomeUnknown).
        app.monitor.simulate(online: true)
        await viewModel.flushQueuedMessages()

        XCTAssertTrue(app.transport.sentPrompts.isEmpty, "the prompt was sent again")
        XCTAssertEqual(app.transport.resumedPrompts, ["Delete the temp folder"])
        let settled = try XCTUnwrap(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(settled.messages.map(\.deliveryState), [.failed])
        XCTAssertFalse(settled.messages.contains { $0.role == .thinking })
        // Release the old process's stalled send only now, so it cannot race the relaunch.
        await gate.open()
    }

    // A message queued behind the unsettled one still goes out once, after it.
    func testQueuedMessageAfterTransmittedOneSendsOnceAfterSettling() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Files", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)

        let gate = PromptGate()
        app.transport.sendBehavior = .wait(gate: gate, output: "never seen")
        viewModel.prompt = "first"
        viewModel.sendPrompt()
        viewModel.prompt = "second"
        viewModel.sendPrompt()
        var states: [MessageDeliveryState] = []
        for _ in 0..<200 where states != [.transmitted, .queued] {
            await Task.yield()
            states = app.snapshotFromDisk()?
                .conversations.first { $0.id == conversation.id }?
                .messages.filter { $0.role == .user }.map(\.deliveryState) ?? []
        }
        XCTAssertEqual(states, [.transmitted, .queued])

        viewModel = try app.relaunch()
        app.transport.resumeBehavior = .succeed(output: "first done")
        app.transport.sendBehavior = .succeed(output: "second done")
        app.monitor.simulate(online: true)
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(app.transport.resumedPrompts, ["first"])
        XCTAssertEqual(app.transport.sentPrompts, ["second"])
        let settled = try XCTUnwrap(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(settled.messages.filter { $0.role == .user }.map(\.deliveryState), [.sent, .sent])
        XCTAssertEqual(settled.messages.filter { $0.role == .agent }.map(\.content), ["first done", "second done"])
        // Release the old process's stalled send only now, so it cannot race the relaunch.
        await gate.open()
    }

    // Each conversation must keep its own row
    func testConversationsWithCollidingToolIDsKeepSeparateHistories() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()

        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Deployer", address: Self.address))

        let staging = viewModel.createConversation(for: agent)
        app.transport.streamedEvents = [
            .toolCall(id: "tool-1", name: "deploy", arguments: ["env": .string("staging")]),
            .toolResult(id: "tool-1", name: "deploy", output: "Deployed staging", state: .completed)
        ]
        app.transport.sendBehavior = .succeed(output: "Staging is live.")
        viewModel.prompt = "Deploy staging"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        let production = viewModel.createConversation(for: agent)
        app.transport.streamedEvents = [
            .toolCall(id: "tool-1", name: "deploy", arguments: ["env": .string("prod")]),
            .toolResult(id: "tool-1", name: "deploy", output: "Deployed prod", state: .completed)
        ]
        app.transport.sendBehavior = .succeed(output: "Prod is live.")
        viewModel.prompt = "Deploy prod"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        viewModel = try app.relaunch()

        XCTAssertEqual(viewModel.conversations.count, 2)
        XCTAssertEqual(viewModel.activeConversationID, production.id)

        let restoredStaging = try XCTUnwrap(viewModel.conversation(withID: staging.id))
        let restoredProduction = try XCTUnwrap(viewModel.conversation(withID: production.id))
        XCTAssertEqual(restoredStaging.title, "Deploy staging")
        XCTAssertEqual(restoredProduction.title, "Deploy prod")
        XCTAssertEqual(
            restoredStaging.messages.map(\.content),
            ["Deploy staging", "Deployed staging", "Staging is live."]
        )
        XCTAssertEqual(
            restoredProduction.messages.map(\.content),
            ["Deploy prod", "Deployed prod", "Prod is live."]
        )
        XCTAssertEqual(
            restoredStaging.messages.first { $0.role == .tool }?.toolArguments,
            ["env": .string("staging")]
        )
        XCTAssertEqual(
            restoredProduction.messages.first { $0.role == .tool }?.toolArguments,
            ["env": .string("prod")]
        )
    }

    // tool call -> app killed -> tool is still running
    func testRunningToolCallIsCompleteOnDiskBeforeTheRoundTripEnds() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()

        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Runner", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)

        app.transport.streamedEvents = [
            .toolCall(
                id: "tool-long",
                name: "run_tests",
                arguments: ["suite": .string("integration"), "timeout": .number(600)]
            )
        ]
        app.transport.sendBehavior = .succeed(output: "All green.")

        var midFlight: ChatSnapshot?
        app.transport.onSend = { [weak app] in
            midFlight = app?.snapshotFromDisk()
        }

        viewModel.prompt = "Run the integration suite"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        let snapshot = try XCTUnwrap(midFlight, "the store was never read mid-flight")
        let stored = try XCTUnwrap(snapshot.conversations.first { $0.id == conversation.id })
        XCTAssertEqual(stored.messages.map(\.role), [.user, .tool])

        let tool = try XCTUnwrap(stored.messages.first { $0.role == .tool })
        XCTAssertEqual(tool.id, "tool-long")
        XCTAssertEqual(tool.toolName, "run_tests")
        XCTAssertEqual(tool.toolState, .running)
        XCTAssertEqual(
            tool.toolArguments,
            ["suite": .string("integration"), "timeout": .number(600)]
        )
    }

    // test if mode and server would survive relaunch
    func testModeAndServerSessionSurviveRelaunch() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()

        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Worker", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)

        viewModel.agentAddressDraft = Self.address
        _ = await viewModel.connectToAgent()
        XCTAssertEqual(app.transport.connectedAddresses, [Self.address])

        viewModel.setMode(.ulw)
        XCTAssertEqual(viewModel.activeMode, .ulw)

        viewModel = try app.relaunch()

        let restored = try XCTUnwrap(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(restored.mode, .ulw)
        XCTAssertEqual(viewModel.activeMode, .ulw)
        XCTAssertEqual(restored.serverSession?["mode"], .string("ulw"))
        XCTAssertEqual(restored.serverSession?["session_id"], .string(conversation.id))
        XCTAssertNil(restored.serverSession?["skip_tool_approval"])
        XCTAssertNil(restored.serverSession?["ulw_turns"])
    }

    // /exec: one tool runs on the host with no LLM turn, and the card shows the answer
    func testExecCommandShowsASuccessCardWithoutStartingATurn() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Ops", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)
        app.transport.execBehavior = .reply(status: "success", text: "max")

        viewModel.prompt = "/exec bash command=whoami"
        viewModel.sendPrompt()
        await viewModel.deliveryCoordinator.lastExecTask?.value

        XCTAssertEqual(app.transport.executedTools, ["bash"])
        XCTAssertEqual(app.transport.executedArguments, [["command": .string("whoami")]])
        XCTAssertTrue(app.transport.sentPrompts.isEmpty, "an EXEC never starts an LLM turn")
        XCTAssertEqual(viewModel.prompt, "")
        XCTAssertNil(viewModel.errorMessage)
        let messages = try XCTUnwrap(viewModel.conversation(withID: conversation.id)).messages
        XCTAssertEqual(messages.map(\.role), [.tool], "no user message is added")
        let card = try XCTUnwrap(messages.first)
        XCTAssertTrue(card.isDirectExec)
        XCTAssertEqual(card.toolName, "bash")
        XCTAssertEqual(card.toolState, .completed)
        XCTAssertEqual(card.content, "max")
    }

    // a refused tool is an answer: the card says why, and the session keeps working
    func testFailedExecShowsAFailedCardAndTheSessionKeepsWorking() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Ops", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)
        let stateBefore = viewModel.connectionState
        app.transport.execBehavior = .reply(status: "error", text: "blocked: bash is not allowed")

        viewModel.prompt = "/exec bash command=whoami"
        viewModel.sendPrompt()
        await viewModel.deliveryCoordinator.lastExecTask?.value

        let failed = try XCTUnwrap(viewModel.conversation(withID: conversation.id)).messages
        XCTAssertEqual(failed.first?.toolState, .failed)
        XCTAssertEqual(failed.first?.content, "blocked: bash is not allowed")
        XCTAssertNil(viewModel.errorMessage, "a refused tool is not a banner-level error")
        XCTAssertEqual(viewModel.connectionState, stateBefore, "a refused tool does not touch the connection state")
        XCTAssertFalse(viewModel.hasFailedDelivery(forConversationID: conversation.id))

        app.transport.sendBehavior = .succeed(output: "Still here.")
        viewModel.prompt = "Are you still there?"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        XCTAssertEqual(app.transport.sentPrompts, ["Are you still there?"])
        let messages = try XCTUnwrap(viewModel.conversation(withID: conversation.id)).messages
        XCTAssertEqual(messages.map(\.role), [.tool, .user, .agent])
        XCTAssertEqual(messages.last?.content, "Still here.")
    }

    // no answer at all (socket lost, timeout) also ends as a failed card, not a stuck Running one
    func testExecThatGetsNoAnswerEndsAsAFailedCard() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Ops", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)
        app.transport.execBehavior = .fail(HostedAgentClientError.closed)

        viewModel.prompt = "/exec bash command=whoami"
        viewModel.sendPrompt()
        await viewModel.deliveryCoordinator.lastExecTask?.value

        let card = try XCTUnwrap(viewModel.conversation(withID: conversation.id)).messages.first
        XCTAssertEqual(card?.toolState, .failed)
        XCTAssertEqual(card?.content, HostedAgentClientError.closed.errorDescription)
        XCTAssertNil(viewModel.errorMessage)
    }

    // a malformed /exec shows the usage line and sends nothing anywhere
    func testMalformedExecCommandShowsTheUsageAndRunsNothing() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Ops", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)

        viewModel.prompt = "/exec"
        viewModel.sendPrompt()

        XCTAssertEqual(viewModel.errorMessage, OIPExecCommand.usage)
        XCTAssertEqual(viewModel.prompt, "/exec", "the text stays so it can be fixed")
        XCTAssertTrue(app.transport.executedTools.isEmpty)
        XCTAssertTrue(app.transport.sentPrompts.isEmpty)
        XCTAssertEqual(try XCTUnwrap(viewModel.conversation(withID: conversation.id)).messages.count, 0)
    }

    // assertions
    private func assertReleaseNotesTimeline(
        _ conversation: Conversation?,
        when phase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let conversation else {
            XCTFail("no active conversation \(phase)", file: file, line: line)
            return
        }

        XCTAssertEqual(conversation.title, "Draft the release notes", "title \(phase)", file: file, line: line)
        XCTAssertEqual(conversation.mode, .safe, "mode \(phase)", file: file, line: line)
        XCTAssertEqual(
            conversation.messages.map(\.role),
            [.user, .tool, .agent],
            "roles \(phase)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            conversation.messages.map(\.content),
            ["Draft the release notes", "Wrote RELEASE.md", "Release notes are ready."],
            "contents \(phase)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            conversation.messages.first?.deliveryState,
            .sent,
            "delivery state \(phase)",
            file: file,
            line: line
        )
        // The placeholder bubble is not history; it must never be on screen once a send settles.
        XCTAssertFalse(
            conversation.messages.contains { $0.role == .thinking },
            "thinking bubble \(phase)",
            file: file,
            line: line
        )

        let tool = conversation.messages.first { $0.role == .tool }
        XCTAssertEqual(tool?.id, "tool-1", "tool id \(phase)", file: file, line: line)
        XCTAssertEqual(tool?.toolName, "write_file", "tool name \(phase)", file: file, line: line)
        XCTAssertEqual(
            tool?.toolArguments,
            ["path": .string("RELEASE.md")],
            "tool arguments \(phase)",
            file: file,
            line: line
        )
        XCTAssertEqual(tool?.toolState, .completed, "tool state \(phase)", file: file, line: line)
    }

    private func waitForPendingApproval(
        on viewModel: ChatViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where viewModel.activePendingApproval == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.activePendingApproval, "no approval card appeared", file: file, line: line)
    }
}

// one install of an app
@MainActor
private final class AppInstallation {
    private(set) var transport: MockAgentTransport
    private(set) var monitor: MockNetworkMonitor

    private let storeURL: URL
    private let defaults: UserDefaults
    private let suiteName: String
    private var viewModel: ChatViewModel?

    init() throws {
        suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OOChatIOSJourney.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("store.sqlite")
        transport = MockAgentTransport()
        monitor = MockNetworkMonitor()
    }

    @discardableResult
    func launch() throws -> ChatViewModel {
        viewModel = nil
        let store = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        transport = MockAgentTransport()
        monitor = MockNetworkMonitor()
        let next = ChatViewModel(store: store, client: transport, networkMonitor: monitor)
        viewModel = next
        return next
    }

    @discardableResult
    func relaunch() throws -> ChatViewModel {
        try launch()
    }

    func snapshotFromDisk() -> ChatSnapshot? {
        try? SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults).load()
    }

    func tearDown() {
        viewModel = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }
}
