import Security
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

    // Mirrored Turn: another device's prompt and streamed reply show here, and the lock follows the turn.
    func testMirroredTurnShowsPromptLocksTheComposerThenUnlocksWithTheReply() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Bot", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)
        let gate = PromptGate()
        app.transport.mirroredBehavior = .wait(gate: gate, output: "Hola")
        app.transport.streamedEvents = [.toolCall(id: "t1", name: "search", arguments: [:])]

        app.transport.onSessionUpdate?(conversation.id, .mirroredTurn(prompt: "Translate hello"))
        for _ in 0..<200 where !viewModel.isProcessing { await Task.yield() }

        XCTAssertTrue(viewModel.isProcessing, "Send is disabled and Stop offered while the other device's turn streams")
        for _ in 0..<200 where !(viewModel.activeConversation?.messages.contains { $0.role == .tool } ?? false) {
            await Task.yield()
        }
        let during = try XCTUnwrap(viewModel.activeConversation).messages
        XCTAssertEqual(during.first?.role, .user)
        XCTAssertEqual(during.first?.content, "Translate hello")
        XCTAssertEqual(during.first?.deliveryState, .sent)
        XCTAssertEqual(during.last { $0.role == .thinking }?.content, "Replying…")
        XCTAssertTrue(during.contains { $0.role == .tool && $0.toolName == "search" })

        await gate.open()
        for _ in 0..<200 where viewModel.isProcessing { await Task.yield() }

        XCTAssertFalse(viewModel.isProcessing)
        let after = try XCTUnwrap(viewModel.activeConversation).messages
        XCTAssertEqual(after.filter { $0.role != .tool }.map(\.content), ["Translate hello", "Hola"])
        XCTAssertEqual(app.transport.sentPrompts, [], "a mirrored turn is never sent from this device")
    }

    func testADeclinedMirroredTurnReleasesTheHeldFramesAtOnce() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Bot", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)
        let gate = PromptGate()
        app.transport.mirroredBehavior = .wait(gate: gate, output: "Hola")
        app.transport.onSessionUpdate?(conversation.id, .mirroredTurn(prompt: "first"))
        for _ in 0..<200 where !viewModel.isProcessing { await Task.yield() }
        XCTAssertEqual(app.transport.releasedMirrorBuffers, 0)

        app.transport.onSessionUpdate?(conversation.id, .mirroredTurn(prompt: "second"))
        for _ in 0..<200 where app.transport.releasedMirrorBuffers == 0 { await Task.yield() }

        XCTAssertEqual(app.transport.releasedMirrorBuffers, 1)
        await gate.open()
    }

    func testStopOnAMirroredTurnCancelsItWithoutOfferingARetry() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Bot", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)
        app.transport.mirroredBehavior = .waitUntilCancelled

        app.transport.onSessionUpdate?(conversation.id, .mirroredTurn(prompt: "long job"))
        for _ in 0..<200 where !viewModel.isProcessing { await Task.yield() }
        viewModel.stopActiveResponse()
        for _ in 0..<200 where viewModel.isProcessing { await Task.yield() }

        XCTAssertFalse(viewModel.isProcessing)
        let user = try XCTUnwrap(viewModel.activeConversation?.messages.first { $0.role == .user })
        XCTAssertEqual(user.deliveryState, .sent, "the other device's prompt is not ours to retry")
    }

    func testCatchingUpAddsTheLatestTurnOnceAndIsIdempotent() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Bot", address: Self.address))
        let conversation = viewModel.createConversation(for: agent)
        let items: [JSONValue] = [
            .object(["type": .string("user"), "content": .string("q")]),
            .object(["type": .string("agent"), "content": .string("a")])
        ]

        app.transport.onSessionUpdate?(conversation.id, .caughtUp(items: items))
        app.transport.onSessionUpdate?(conversation.id, .caughtUp(items: items))
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(viewModel.activeConversation?.messages.map(\.content), ["q", "a"])
        XCTAssertFalse(viewModel.isProcessing)
    }

    // Link a freshly onboarded phone to a Mac: the Mac's agent arrives with its Agent Name, History Restore
    // fills it with the Mac's chat, then a turn sent on the Mac plays here. Both devices run the Kit's link
    // flow, joined in memory, and no agent is added by hand.
    func testALinkedPhoneRestoresTheMacsChatThenWatchesATurnSentOnTheMac() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let mac = InMemoryPrivateKeyStore()
        let macAddress = try OIPSigner(keyStore: mac).address()
        viewModel.historyFetcher = OwnerOnlyHost(owner: macAddress, asker: app.identityStore, owned: [
            try hostedSession("shared", [("user", "Hi"), ("assistant", "Hello")])
        ])
        XCTAssertTrue(viewModel.agents.isEmpty)
        XCTAssertFalse(app.identityStore.isLinked)
        XCTAssertFalse(mac.isLinked)

        let link = InMemoryLink()
        let phoneFlow = DeviceLinkFlow(
            role: .receiving,
            keyStore: app.identityStore,
            onReplaced: { previous in Task { await viewModel.adoptReplacedIdentity(previousAddress: previous) } },
            onAgentNames: { try viewModel.applyLinkedAgentNames($0) },
            receive: { try await link.receive($0, $1) }
        )
        let macAgents = [DeviceLinkAgentName(address: Self.address, name: "Bot")].compactMap { $0 }
        let macFlow = DeviceLinkFlow(role: .giving, keyStore: mac, agentNames: { macAgents }, ownerCheck: { true },
                                     give: { try await link.give($0, $1) })
        phoneFlow.start()
        guard case .showingCode(let offer) = phoneFlow.step else { return XCTFail("the phone shows its code") }
        await eventually { link.isWaiting }
        macFlow.start()
        macFlow.submit(try offer.qrPayload)
        await eventually { macFlow.step == .confirmingSend }
        macFlow.confirm()
        await eventually { if case .confirmingReplace = phoneFlow.step { true } else { false } }
        phoneFlow.confirm()
        await eventually { phoneFlow.step == .done(address: macAddress) && macFlow.step == .done(address: macAddress) }

        XCTAssertTrue(app.identityStore.isLinked)
        XCTAssertTrue(mac.isLinked)
        // No refresh: the link itself brings the Mac's chats in.
        await eventually { viewModel.conversation(withID: "shared") != nil }
        XCTAssertEqual(viewModel.identity?.address, macAddress)
        XCTAssertEqual(viewModel.agents.map(\.name), ["Bot"])
        XCTAssertEqual(viewModel.conversation(withID: "shared")?.messages.map(\.content), ["Hi", "Hello"])

        viewModel.selectConversation(withID: "shared")
        app.transport.mirroredBehavior = .succeed(output: "Sure")
        app.transport.onSessionUpdate?("shared", .mirroredTurn(prompt: "One more?"))
        await eventually { !viewModel.isProcessing && viewModel.activeConversation?.messages.count == 4 }

        XCTAssertEqual(viewModel.activeConversation?.messages.map(\.content), ["Hi", "Hello", "One more?", "Sure"])
        XCTAssertEqual(app.transport.sentPrompts, [], "the turn was the Mac's")
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

    // MARK: - Tool row states

    // The host announces the tool, then asks permission. Until you answer, it isn't running.
    func testToolWaitingOnItsApprovalCardIsAwaitingApproval() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        let conversation = try startChat(on: viewModel)
        app.transport.eventsBeforeInteractions = [touchToolCall]
        app.transport.approvalRequests = [touchApproval]

        viewModel.prompt = "Use bash to run: touch a.txt"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)

        let tool = try XCTUnwrap(viewModel.activeConversation?.messages.first { $0.role == .tool })
        XCTAssertEqual(viewModel.toolRowState(for: tool, in: conversation.id), .awaitingApproval)

        viewModel.allowPendingApprovalOnce(id: touchApproval.id)
        await viewModel.sendTask?.value
    }

    // The host reports a skipped tool as an error ("User rejected…"); you chose it, so it's Skipped.
    func testSkippedToolStaysSkippedWhenTheHostReportsItAsAnError() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()
        let conversation = try startChat(on: viewModel)
        app.transport.eventsBeforeInteractions = [touchToolCall]
        app.transport.approvalRequests = [touchApproval]
        app.transport.streamedEvents = [
            .toolResult(id: "tool-touch", name: "bash", output: "Error: User rejected tool 'bash'.", state: .failed)
        ]

        viewModel.prompt = "Use bash to run: touch a.txt"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        viewModel.skipPendingApproval(id: touchApproval.id)
        await viewModel.sendTask?.value

        var tool = try XCTUnwrap(viewModel.activeConversation?.messages.first { $0.role == .tool })
        XCTAssertEqual(tool.toolState, .skipped)
        XCTAssertEqual(viewModel.toolRowState(for: tool, in: conversation.id), .skipped)

        viewModel = try app.relaunch()
        tool = try XCTUnwrap(viewModel.activeConversation?.messages.first { $0.role == .tool })
        XCTAssertEqual(tool.toolState, .skipped, "after relaunch")
    }

    // Stop while a tool runs: it never finishes, so it must not spin forever, even after relaunch.
    func testToolRunningWhenYouStopIsInterruptedAndStaysThatWay() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        var viewModel = try app.launch()
        _ = try startChat(on: viewModel)
        app.transport.eventsBeforeInteractions = [touchToolCall]
        app.transport.sendBehavior = .waitUntilCancelled

        viewModel.prompt = "Use bash to run: touch a.txt"
        viewModel.sendPrompt()
        for _ in 0..<100 where viewModel.activeConversation?.messages.contains(where: { $0.role == .tool }) != true {
            await Task.yield()
        }
        viewModel.stopActiveResponse()
        await viewModel.sendTask?.value

        XCTAssertEqual(viewModel.activeConversation?.messages.first { $0.role == .tool }?.toolState, .interrupted)
        viewModel = try app.relaunch()
        XCTAssertEqual(
            viewModel.activeConversation?.messages.first { $0.role == .tool }?.toolState,
            .interrupted,
            "after relaunch"
        )
    }

    // After you stop a batch, the host sends the rest of it no result, but the reply still comes.
    func testToolsLeftWithoutAResultWhenTheReplyArrivesAreInterrupted() async throws {
        let app = try AppInstallation()
        defer { app.tearDown() }
        let viewModel = try app.launch()
        _ = try startChat(on: viewModel)
        app.transport.eventsBeforeInteractions = [
            touchToolCall,
            .toolCall(id: "tool-echo", name: "bash", arguments: ["command": .string("echo hi")])
        ]
        app.transport.streamedEvents = [
            .toolResult(id: "tool-touch", name: "bash", output: "", state: .completed)
        ]
        app.transport.sendBehavior = .succeed(output: "Stopped as you asked.")

        viewModel.prompt = "Run two commands"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        let tools = viewModel.activeConversation?.messages.filter { $0.role == .tool } ?? []
        XCTAssertEqual(tools.map(\.toolState), [.completed, .interrupted])
    }

    private var touchToolCall: HostedAgentEvent {
        .toolCall(id: "tool-touch", name: "bash", arguments: ["command": .string("touch a.txt")])
    }

    private var touchApproval: ToolApprovalRequest {
        ToolApprovalRequest(id: "approval-touch", tool: "bash", arguments: ["command": .string("touch a.txt")])
    }

    private func startChat(on viewModel: ChatViewModel) throws -> Conversation {
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Runner", address: Self.address))
        return viewModel.createConversation(for: agent)
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
        await viewModel.settleModeChange()
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

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func hostedSession(_ id: String, _ pairs: [(String, String)]) throws -> ConnectOnionHostedSession {
        let object: [String: Any] = [
            "session_id": id, "status": "done", "prompt": pairs.first?.1 ?? "", "created": 100.0,
            "session": ["messages": pairs.map { ["role": $0.0, "content": $0.1] }]
        ]
        return try JSONDecoder().decode(ConnectOnionHostedSession.self, from: JSONSerialization.data(withJSONObject: object))
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

/// A host that returns its Hosted History only to the Address that owns it, as signed by the asking device.
private final class OwnerOnlyHost: SessionsFetching {
    private let owner: String
    private let asker: any PrivateKeyStoring
    private let owned: [ConnectOnionHostedSession]

    init(owner: String, asker: any PrivateKeyStoring, owned: [ConnectOnionHostedSession]) {
        self.owner = owner
        self.asker = asker
        self.owned = owned
    }

    func sessions(agentAddress: String) async throws -> [ConnectOnionHostedSession] {
        try OIPSigner(keyStore: asker).address() == owner ? owned : []
    }
}

/// Two devices' link flows joined in memory: the receiver's side waits here and the giver's side plays
/// the exchange against it, so no socket opens.
@MainActor
private final class InMemoryLink {
    private var receiver: DeviceLinkReceiver?
    private var accept: (@Sendable (DeviceLinkIdentity) async -> Bool)?
    private var finish: CheckedContinuation<DeviceLinkIdentity, Error>?
    var isWaiting: Bool { finish != nil }

    func receive(
        _ receiver: DeviceLinkReceiver,
        _ accept: @escaping @Sendable (DeviceLinkIdentity) async -> Bool
    ) async throws -> DeviceLinkIdentity {
        try await withCheckedThrowingContinuation { finish in
            self.receiver = receiver
            self.accept = accept
            self.finish = finish
        }
    }

    func give(_ giver: DeviceLinkGiver, _ approve: @escaping @Sendable () async -> Bool) async throws {
        guard let receiver, let accept, let finish else { throw DeviceLinkError.cancelled }
        do {
            let verified = try giver.verify(try receiver.start())
            guard await approve() else { throw DeviceLinkError.cancelled }
            let identity = try receiver.accept(try giver.seal(for: verified))
            guard await accept(identity) else { throw DeviceLinkError.cancelled }
            finish.resume(returning: identity)
        } catch {
            finish.resume(throwing: error)
            throw error
        }
    }
}

// one install of an app
@MainActor
private final class AppInstallation {
    private(set) var transport: MockAgentTransport
    private(set) var monitor: MockNetworkMonitor
    /// This install's own Keychain items, so a test can link without touching the simulator's real Identity.
    let identityStore: IdentityStore

    private let identityService = "OOChatIOSJourney.identity.\(UUID().uuidString)"
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
        identityStore = IdentityStore(service: identityService)
    }

    @discardableResult
    func launch() throws -> ChatViewModel {
        viewModel = nil
        let store = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        transport = MockAgentTransport()
        monitor = MockNetworkMonitor()
        let next = ChatViewModel(store: store, identityStore: identityStore, client: transport, networkMonitor: monitor)
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
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: identityService] as CFDictionary)
    }
}
