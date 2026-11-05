import Combine
import XCTest
@testable import OOChatIOS

@MainActor
final class NetworkRecoveryTests: XCTestCase {
    private let address = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    func testMonitorStartsOnInitAndOfflineFlagTracksNetwork() {
        let (viewModel, _, monitor) = makeEnvironment()

        XCTAssertTrue(monitor.started)
        XCTAssertFalse(viewModel.isOffline)

        monitor.simulate(online: false)
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertEqual(viewModel.connectionState, .disconnected)

        monitor.simulate(online: true)
        XCTAssertFalse(viewModel.isOffline)
    }

    func testStayingOnlineDoesNotTriggerRecovery() {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)

        monitor.simulate(online: true)

        XCTAssertNil(viewModel.recoveryTask)
        XCTAssertTrue(transport.connectedAddresses.isEmpty)
    }

    // queueing while offline
    func testSendWhileOfflineQueuesMessageWithoutNetworkCall() {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)

        viewModel.prompt = "queued while offline"
        viewModel.sendPrompt()

        let messages = viewModel.activeConversation?.messages ?? []
        let userMessage = messages.last { $0.role == .user }
        XCTAssertEqual(userMessage?.deliveryState, .queued)
        XCTAssertEqual(userMessage?.content, "queued while offline")
        XCTAssertFalse(messages.contains { $0.role == .thinking })
        XCTAssertTrue(transport.sentPrompts.isEmpty)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testMultipleOfflineSendsQueueInOrder() {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)

        viewModel.prompt = "first"
        viewModel.sendPrompt()
        viewModel.prompt = "second"
        viewModel.sendPrompt()

        let queued = (viewModel.activeConversation?.messages ?? [])
            .filter { $0.role == .user && $0.deliveryState == .queued }
        XCTAssertEqual(queued.map(\.content), ["first", "second"])
        XCTAssertTrue(transport.sentPrompts.isEmpty)
    }

    func testSecondMessageQueuesBehindActiveResponseInSameConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let firstGate = PromptGate()
        transport.sendBehaviorsByPrompt["first"] = .wait(gate: firstGate, output: "first reply")

        viewModel.prompt = "first"
        viewModel.sendPrompt()
        await waitForSentPrompt("first", transport: transport)

        viewModel.prompt = "second"
        viewModel.sendPrompt()

        XCTAssertEqual(transport.sentPrompts, ["first"])
        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertEqual(
            viewModel.activeConversation?.messages.filter {
                $0.role == .user && $0.deliveryState == .queued
            }.map(\.content),
            ["first", "second"]
        )

        await firstGate.open()
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(transport.sentPrompts, ["first", "second"])
        XCTAssertFalse(viewModel.isProcessing)
        let replies = viewModel.activeConversation?.messages.filter { $0.role == .agent }.map(\.content) ?? []
        XCTAssertEqual(Array(replies.suffix(2)), ["first reply", "mock reply"])
    }

    func testDifferentConversationsCanRunWithoutStealingFocus() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let firstConversation = viewModel.activeConversation!
        let firstGate = PromptGate()
        let secondGate = PromptGate()
        transport.sendBehaviorsByPrompt = [
            "first": .wait(gate: firstGate, output: "first reply"),
            "second": .wait(gate: secondGate, output: "second reply")
        ]

        viewModel.prompt = "first"
        viewModel.sendPrompt()
        await waitForSentPrompt("first", transport: transport)

        let secondConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "second"
        viewModel.sendPrompt()
        await waitForSentPrompt("second", transport: transport)

        XCTAssertTrue(viewModel.isProcessing(conversationID: firstConversation.id))
        XCTAssertTrue(viewModel.isProcessing(conversationID: secondConversation.id))
        XCTAssertEqual(viewModel.activeConversationID, secondConversation.id)
        XCTAssertEqual(viewModel.activityState(forConversationID: firstConversation.id), .working)
        XCTAssertNil(viewModel.backgroundActivityState, "working alone does not show a toolbar dot")

        await firstGate.open()
        await waitUntilIdle(firstConversation.id, on: viewModel)

        XCTAssertEqual(viewModel.activeConversationID, secondConversation.id)
        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertEqual(viewModel.activityState(forConversationID: firstConversation.id), .completedUnread)
        XCTAssertEqual(viewModel.backgroundActivityState, .completedUnread)
        XCTAssertTrue(
            viewModel.conversation(withID: firstConversation.id)?.messages.contains {
                $0.role == .agent && $0.content == "first reply"
            } ?? false
        )

        await secondGate.open()
        await waitUntilIdle(secondConversation.id, on: viewModel)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertNil(viewModel.activityState(forConversationID: secondConversation.id))
        XCTAssertEqual(viewModel.backgroundActivityState, .completedUnread)

        viewModel.selectConversation(firstConversation)
        XCTAssertNil(viewModel.activityState(forConversationID: firstConversation.id))
        XCTAssertNil(viewModel.backgroundActivityState)
    }

    func testStopMarksActiveMessageCancelledAndRetryResendsIt() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .waitUntilCancelled

        viewModel.prompt = "long task"
        viewModel.sendPrompt()
        await waitForSentPrompt("long task", transport: transport)
        let task = viewModel.sendTask

        viewModel.stopActiveResponse()
        await task?.value

        let cancelled = viewModel.activeConversation?.messages.first {
            $0.role == .user && $0.content == "long task"
        }
        XCTAssertEqual(cancelled?.deliveryState, .cancelled)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.activeConversation?.messages.contains { $0.role == .thinking } ?? true)

        transport.sendBehavior = .succeed(output: "retried")
        viewModel.retryMessage(cancelled!)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.sentPrompts, ["long task", "long task"])
        XCTAssertEqual(
            viewModel.activeConversation?.messages.first { $0.id == cancelled?.id }?.deliveryState,
            .sent
        )
    }

    func testStoppingLeavesQueuedFollowUpPausedUntilTheUserSendsAgain() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehaviorsByPrompt["long task"] = .waitUntilCancelled

        viewModel.prompt = "long task"
        viewModel.sendPrompt()
        await waitForSentPrompt("long task", transport: transport)
        let task = viewModel.sendTask

        viewModel.prompt = "follow up"
        viewModel.sendPrompt()
        viewModel.prompt = "draft"
        viewModel.stopActiveResponse()
        await task?.value
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(transport.sentPrompts, ["long task"])
        let userMessages = viewModel.activeConversation?.messages.filter { $0.role == .user } ?? []
        XCTAssertEqual(userMessages.first { $0.content == "long task" }?.deliveryState, .cancelled)
        XCTAssertEqual(userMessages.first { $0.content == "follow up" }?.deliveryState, .queued)
        XCTAssertEqual(viewModel.prompt, "draft")
        XCTAssertFalse(viewModel.isProcessing)

        viewModel.sendPrompt()
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(transport.sentPrompts, ["long task", "follow up", "draft"])
        XCTAssertTrue(
            viewModel.activeConversation?.messages.filter { $0.role == .user }.allSatisfy {
                $0.deliveryState != .queued
            } ?? false
        )
    }

    func testStoppingActiveConversationLeavesBackgroundDeliveryRunning() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let backgroundConversation = viewModel.activeConversation!
        let backgroundGate = PromptGate()
        transport.sendBehaviorsByPrompt = [
            "background": .wait(gate: backgroundGate, output: "background reply"),
            "active": .waitUntilCancelled
        ]

        viewModel.prompt = "background"
        viewModel.sendPrompt()
        await waitForSentPrompt("background", transport: transport)

        let activeConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "active"
        viewModel.sendPrompt()
        await waitForSentPrompt("active", transport: transport)
        let activeTask = viewModel.sendTask

        viewModel.stopActiveResponse()
        await activeTask?.value

        XCTAssertFalse(viewModel.isProcessing(conversationID: activeConversation.id))
        XCTAssertTrue(viewModel.isProcessing(conversationID: backgroundConversation.id))

        await backgroundGate.open()
        await waitUntilIdle(backgroundConversation.id, on: viewModel)
        XCTAssertTrue(
            viewModel.conversation(withID: backgroundConversation.id)?.messages.contains {
                $0.role == .agent && $0.content == "background reply"
            } ?? false
        )
    }

    // automatic reconnection and flush
    func testReconnectionFlushesQueuedMessagesInOrder() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)
        viewModel.prompt = "first"
        viewModel.sendPrompt()
        viewModel.prompt = "second"
        viewModel.sendPrompt()

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value

        XCTAssertEqual(transport.connectedAddresses, [address], "reconnection should happen automatically")
        XCTAssertEqual(transport.sentPrompts, ["first", "second"])
        let messages = viewModel.activeConversation?.messages ?? []
        let userMessages = messages.filter { $0.role == .user }
        XCTAssertTrue(userMessages.allSatisfy { $0.deliveryState == .sent })
        XCTAssertEqual(messages.filter { $0.role == .agent && $0.content == "mock reply" }.count, 2)
        XCTAssertFalse(messages.contains { $0.role == .thinking })
        XCTAssertEqual(viewModel.connectionState, .connected)
    }

    func testReconnectionWithNothingQueuedStillReconnects() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value

        XCTAssertEqual(transport.connectedAddresses, [address])
        XCTAssertTrue(transport.sentPrompts.isEmpty)
    }

    func testRecoveryRemainsScopedToOriginConversationAfterSelectionChanges() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        let firstAgent = setUpAgentAndConversation(viewModel)
        let firstConversation = viewModel.activeConversation!
        let secondAddress = "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        let secondAgent = viewModel.saveAgent(name: "Second", address: secondAddress)!
        let secondConversation = viewModel.createConversation(for: secondAgent)
        viewModel.selectConversation(firstConversation)
        let gate = PromptGate()
        transport.connectBehavior = .wait(gate: gate, output: "")

        monitor.simulate(online: false)
        monitor.simulate(online: true)
        viewModel.selectConversation(secondConversation)
        await gate.open()
        await viewModel.recoveryTask?.value

        XCTAssertEqual(transport.connectedAddresses, [firstAgent.address])
        XCTAssertEqual(viewModel.activeConversationID, secondConversation.id)
        XCTAssertEqual(viewModel.connectionState, .disconnected)
        viewModel.selectConversation(firstConversation)
        XCTAssertEqual(viewModel.connectionState, .connected)
    }

    func testFlushStopsWhenNetworkDropsAgain() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)
        viewModel.prompt = "first"
        viewModel.sendPrompt()
        viewModel.prompt = "second"
        viewModel.sendPrompt()
        transport.onSend = {
            monitor.simulate(online: false)
        }

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.sentPrompts, ["first"], "flush should stop once offline again")
        let queued = (viewModel.activeConversation?.messages ?? [])
            .filter { $0.role == .user && $0.deliveryState == .queued }
        XCTAssertEqual(queued.map(\.content), ["second"])
    }

    func testInterruptedDeliveryMarksMessageFailed() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .fail(HostedAgentClientError.timeout)

        viewModel.prompt = "will fail"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        let messages = viewModel.activeConversation?.messages ?? []
        let userMessage = messages.last { $0.role == .user }
        XCTAssertEqual(userMessage?.deliveryState, .failed)
        XCTAssertFalse(messages.contains { $0.role == .thinking })
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testRetryThatFailsWhileOfflineLeavesOnlyTheOfflineBanner() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.connectBehavior = .fail(HostedAgentClientError.timeout)
        monitor.simulate(online: false)

        viewModel.retryConnectivity()
        await viewModel.recoveryTask?.value

        XCTAssertTrue(viewModel.shouldShowOfflineBanner)
        XCTAssertNil(
            viewModel.errorMessage,
            "a failed retry while offline has nothing to add to the offline banner"
        )
        XCTAssertFalse(viewModel.isRetryingConnectivity)
    }

    func testRetryReportsItsProgressOnTheRetryControl() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let gate = PromptGate()
        transport.connectBehavior = .wait(gate: gate, output: "")
        monitor.simulate(online: false)

        viewModel.retryConnectivity()
        XCTAssertTrue(viewModel.isRetryingConnectivity, "the button has to show the attempt is running")

        await gate.open()
        await viewModel.recoveryTask?.value

        XCTAssertFalse(viewModel.isRetryingConnectivity)
        XCTAssertFalse(viewModel.isOffline, "a retry that connects is proof the network is back")
    }

    func testRetryWhileAPromptStillHoldsTheConnectionStaysQuiet() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.connectBehavior = .fail(HostedAgentClientError.busy)
        monitor.simulate(online: false)

        viewModel.retryConnectivity()
        await viewModel.recoveryTask?.value

        XCTAssertTrue(viewModel.shouldShowOfflineBanner)
        XCTAssertNil(
            viewModel.errorMessage,
            "a connection held by its own in-flight prompt is not a failure the user can act on"
        )
    }

    // one dropped network, one banner
    func testConnectionLossAfterGoingOfflineKeepsOnlyTheOfflineBanner() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let gate = PromptGate()
        transport.sendBehavior = .waitThenFail(gate: gate, error: HostedAgentClientError.closed)
        viewModel.prompt = "in flight"
        viewModel.sendPrompt()

        monitor.simulate(online: false)
        await gate.open()
        await viewModel.sendTask?.value

        XCTAssertTrue(viewModel.shouldShowOfflineBanner)
        XCTAssertNil(viewModel.errorMessage, "the offline banner already reports the dropped network")
        let userMessage = (viewModel.activeConversation?.messages ?? []).last { $0.role == .user }
        XCTAssertEqual(userMessage?.deliveryState, .failed, "the failure still reaches the user on the bubble")
    }

    func testGoingOfflineRetractsAConnectionErrorRaisedFirst() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .fail(HostedAgentClientError.closed)
        viewModel.prompt = "will drop"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value
        XCTAssertNotNil(viewModel.errorMessage, "nothing knows the network is gone yet")

        monitor.simulate(online: false)

        XCTAssertTrue(viewModel.shouldShowOfflineBanner)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testGoingOfflineKeepsBannersThatAreNotAboutTheNetwork() {
        let (viewModel, _, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.errorMessage = "That photo is larger than 10 MB."

        monitor.simulate(online: false)

        XCTAssertEqual(viewModel.errorMessage, "That photo is larger than 10 MB.")
    }

    func testAgentReportedFailureWhileOfflineStillRaisesABanner() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let gate = PromptGate()
        transport.sendBehavior = .waitThenFail(
            gate: gate,
            error: HostedAgentClientError.server("out of disk")
        )
        viewModel.prompt = "in flight"
        viewModel.sendPrompt()

        monitor.simulate(online: false)
        await gate.open()
        await viewModel.sendTask?.value

        XCTAssertTrue(
            viewModel.errorMessage?.contains("out of disk") ?? false,
            "an agent-side failure says something the offline banner does not"
        )
    }

    func testRetryResendsFailedMessage() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .fail(HostedAgentClientError.timeout)
        viewModel.prompt = "flaky"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value
        let failed = (viewModel.activeConversation?.messages ?? []).last { $0.role == .user }!
        XCTAssertEqual(failed.deliveryState, .failed)

        transport.sendBehavior = .succeed(output: "recovered")
        viewModel.retryMessage(failed)
        await viewModel.sendTask?.value

        let messages = viewModel.activeConversation?.messages ?? []
        let userMessage = messages.first { $0.id == failed.id }
        XCTAssertEqual(userMessage?.deliveryState, .sent)
        XCTAssertTrue(messages.contains { $0.role == .agent && $0.content == "recovered" })
        XCTAssertEqual(transport.sentPrompts, ["flaky", "flaky"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRetryWhileOfflineRequeuesForLaterFlush() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .fail(HostedAgentClientError.timeout)
        viewModel.prompt = "flaky"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value
        let failed = (viewModel.activeConversation?.messages ?? []).last { $0.role == .user }!

        monitor.simulate(online: false)
        transport.sendBehavior = .succeed(output: "after reconnect")
        viewModel.retryMessage(failed)

        var requeued = (viewModel.activeConversation?.messages ?? []).first { $0.id == failed.id }
        XCTAssertEqual(requeued?.deliveryState, .queued)
        XCTAssertEqual(transport.sentPrompts, ["flaky"], "no send while offline")

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value

        requeued = (viewModel.activeConversation?.messages ?? []).first { $0.id == failed.id }
        XCTAssertEqual(requeued?.deliveryState, .sent)
        XCTAssertEqual(transport.sentPrompts, ["flaky", "flaky"])
    }

    func testRetryIgnoresMessagesThatDidNotFail() {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let sentMessage = ChatMessage(role: .user, content: "already sent", deliveryState: .sent)

        viewModel.retryMessage(sentMessage)

        XCTAssertTrue(transport.sentPrompts.isEmpty)
        XCTAssertNil(viewModel.sendTask)
    }

    // connecting while offline
    func testConnectToAgentWhileOfflineFailsFast() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        monitor.simulate(online: false)
        viewModel.agentAddressDraft = address

        let agent = await viewModel.connectToAgent()

        XCTAssertNil(agent)
        XCTAssertTrue(transport.connectedAddresses.isEmpty)
        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertTrue(viewModel.errorMessage?.contains("offline") ?? false)
    }

    // persistence
    func testDeliveryStateRoundTripsThroughRepository() throws {
        let defaults = makeDefaults()
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        var conversation = Conversation(agentID: "agent-1", agentAddress: address)
        conversation.messages.append(ChatMessage(role: .user, content: "pending", deliveryState: .queued))
        store.upsertConversation(conversation)

        let loaded = store.load().conversations.first { $0.id == conversation.id }
        let message = loaded?.messages.first { $0.content == "pending" }

        XCTAssertEqual(message?.deliveryState, .queued)
    }

    func testCancelledDeliveryStateRoundTripsThroughRepository() throws {
        let defaults = makeDefaults()
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        var conversation = Conversation(agentID: "agent-1", agentAddress: address)
        conversation.messages.append(
            ChatMessage(role: .user, content: "stopped", deliveryState: .cancelled)
        )
        store.upsertConversation(conversation)

        let loaded = store.load().conversations.first { $0.id == conversation.id }
        let cancelled = loaded?.messages.first { $0.content == "stopped" }
        XCTAssertEqual(cancelled?.deliveryState, .cancelled)
    }

    func testRepositoryUpdatesDeliveryStateOfExistingMessage() throws {
        let defaults = makeDefaults()
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        var conversation = Conversation(agentID: "agent-1", agentAddress: address)
        conversation.messages.append(ChatMessage(role: .user, content: "pending", deliveryState: .queued))
        store.upsertConversation(conversation)

        let index = conversation.messages.firstIndex { $0.content == "pending" }!
        conversation.messages[index].deliveryState = .failed
        store.upsertConversation(conversation)

        let loaded = store.load().conversations.first { $0.id == conversation.id }
        let message = loaded?.messages.first { $0.content == "pending" }
        XCTAssertEqual(message?.deliveryState, .failed)
    }

    func testStreamingToolCallIsUpdatedInPlaceAndPersistsWithResponse() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.streamedEvents = [
            .toolCall(
                id: "tool-read-1",
                name: "read_file",
                arguments: ["path": .string("README.md")]
            ),
            .toolResult(
                id: "tool-read-1",
                name: "read_file",
                output: "# Project notes",
                state: .completed
            )
        ]
        transport.sendBehavior = .succeed(output: "I found the project notes.")

        viewModel.prompt = "Read the project notes"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        let messages = viewModel.activeConversation?.messages ?? []
        let toolMessages = messages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.count, 1)
        XCTAssertEqual(toolMessages.first?.id, "tool-read-1")
        XCTAssertEqual(toolMessages.first?.toolName, "read_file")
        XCTAssertEqual(toolMessages.first?.toolArguments, ["path": .string("README.md")])
        XCTAssertEqual(toolMessages.first?.toolState, .completed)
        XCTAssertEqual(toolMessages.first?.content, "# Project notes")
        XCTAssertEqual(messages.last?.role, .agent)
        XCTAssertEqual(messages.last?.content, "I found the project notes.")
    }

    func testStreamedEventsRemainScopedToOriginConversationAfterSelectionChanges() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let originConversation = viewModel.activeConversation!
        let gate = PromptGate()
        transport.sendBehavior = .wait(gate: gate, output: "Background result")
        transport.streamedEvents = [
            .toolCall(id: "background-tool", name: "read_file", arguments: [:]),
            .toolResult(
                id: "background-tool",
                name: "read_file",
                output: "Background output",
                state: .completed
            )
        ]

        viewModel.prompt = "Run in the background"
        viewModel.sendPrompt()
        await waitForSentPrompt(transport: transport)
        let foregroundConversation = viewModel.createConversation(for: agent)

        await gate.open()
        await waitUntilIdle(originConversation.id, on: viewModel)

        let originMessages = viewModel.conversation(withID: originConversation.id)?.messages ?? []
        XCTAssertEqual(originMessages.first { $0.id == "background-tool" }?.content, "Background output")
        XCTAssertEqual(originMessages.last?.content, "Background result")
        XCTAssertFalse(
            (viewModel.conversation(withID: foregroundConversation.id)?.messages ?? [])
                .contains { $0.id == "background-tool" }
        )
    }

    func testSafeModeWaitsForAllowOnce() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create the prompt"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)

        XCTAssertEqual(viewModel.activePendingApproval?.request.tool, "write")
        XCTAssertTrue(viewModel.isProcessing)

        viewModel.allowPendingApprovalOnce(id: viewModel.activePendingApproval!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testSafeModeCanTrustToolForSession() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "bash")]

        viewModel.prompt = "Run the checks"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        viewModel.trustPendingApprovalForSession(id: viewModel.activePendingApproval!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowSession])
        XCTAssertNil(viewModel.activePendingApproval)
    }

    func testSafeModeSkipsToolAndContinues() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "bash")]

        viewModel.prompt = "Run a command"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        viewModel.skipPendingApproval(id: viewModel.activePendingApproval!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.rejectSoft(feedback: nil)])
        XCTAssertTrue(viewModel.activeConversation?.messages.contains {
            $0.role == .agent && $0.content == "mock reply"
        } ?? false)
    }

    func testPendingApprovalCanOnlyResolveOnce() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let approvalID = viewModel.activePendingApproval!.id
        viewModel.allowPendingApprovalOnce(id: approvalID)
        viewModel.skipPendingApproval(id: approvalID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
    }

    func testStoppingPendingApprovalWaitsForRejectionBeforeCancelling() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]
        transport.waitAfterInteractionsUntilCancelled = true

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let conversationID = viewModel.activeConversation!.id
        let task = viewModel.sendTask

        viewModel.stopActiveResponse()
        await task?.value

        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
        XCTAssertEqual(transport.interactionResponseWaits.count, 1)
        XCTAssertEqual(transport.interactionResponseWaits.first?.conversationID, conversationID)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testBackgroundApprovalDoesNotBlockSendingOrStealFocus() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let approvalConversation = viewModel.activeConversation!
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let approvalID = viewModel.activePendingApproval!.id

        transport.approvalRequests = []
        let secondConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "Answer here"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        XCTAssertEqual(viewModel.activeConversationID, secondConversation.id)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertTrue(viewModel.isProcessing(conversationID: approvalConversation.id))
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: approvalConversation.id))
        XCTAssertEqual(viewModel.activityState(forConversationID: approvalConversation.id), .actionRequired)
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertNil(viewModel.activePendingPlanReview)
        XCTAssertNil(viewModel.sendTask)
        XCTAssertTrue(viewModel.hasBackgroundPendingInteraction)
        XCTAssertEqual(viewModel.backgroundActivityState, .actionRequired)
        XCTAssertTrue(
            viewModel.conversation(withID: secondConversation.id)?.messages.contains {
                $0.role == .agent && $0.content == "mock reply"
            } ?? false
        )

        viewModel.selectConversation(approvalConversation)
        XCTAssertEqual(viewModel.activePendingApproval?.id, approvalID)
        XCTAssertNotNil(viewModel.sendTask)
        viewModel.allowPendingApprovalOnce(id: approvalID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
        XCTAssertFalse(viewModel.hasPendingInteraction(forConversationID: approvalConversation.id))
        XCTAssertFalse(viewModel.hasBackgroundPendingInteraction)
    }

    func testBackgroundActionRequiredOverridesUnreadCompletion() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let completedConversation = viewModel.activeConversation!
        let completionGate = PromptGate()
        transport.sendBehaviorsByPrompt["Finish in background"] = .wait(
            gate: completionGate,
            output: "finished"
        )

        viewModel.prompt = "Finish in background"
        viewModel.sendPrompt()
        await waitForSentPrompt("Finish in background", transport: transport)

        let approvalConversation = viewModel.createConversation(for: agent)
        await completionGate.open()
        await waitUntilIdle(completedConversation.id, on: viewModel)
        XCTAssertEqual(viewModel.backgroundActivityState, .completedUnread)

        transport.approvalRequests = [approvalRequest(tool: "write")]
        viewModel.prompt = "Wait for approval"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let approvalID = viewModel.activePendingApproval!.id

        _ = viewModel.createConversation(for: agent)

        XCTAssertEqual(viewModel.activityState(forConversationID: completedConversation.id), .completedUnread)
        XCTAssertEqual(viewModel.activityState(forConversationID: approvalConversation.id), .actionRequired)
        XCTAssertEqual(viewModel.backgroundActivityState, .actionRequired)

        viewModel.selectConversation(approvalConversation)
        viewModel.allowPendingApprovalOnce(id: approvalID)
        await viewModel.sendTask?.value

        XCTAssertEqual(viewModel.backgroundActivityState, .completedUnread)
    }

    func testSameApprovalIDCanWaitInTwoConversationsIndependently() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let firstConversation = viewModel.activeConversation!
        let sharedRequest = approvalRequest(tool: "write")
        transport.approvalRequests = [sharedRequest]

        viewModel.prompt = "First approval"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)

        let secondConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "Second approval"
        viewModel.sendPrompt()
        await waitForActivePendingApproval(on: viewModel)

        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: firstConversation.id))
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: secondConversation.id))
        XCTAssertEqual(viewModel.activePendingApproval?.id, sharedRequest.id)

        viewModel.allowPendingApprovalOnce(id: sharedRequest.id)
        await viewModel.sendTask?.value
        XCTAssertFalse(viewModel.hasPendingInteraction(forConversationID: secondConversation.id))
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: firstConversation.id))

        viewModel.selectConversation(firstConversation)
        viewModel.skipPendingApproval(id: sharedRequest.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(
            transport.approvalDecisions,
            [.allowOnce, .rejectSoft(feedback: nil)]
        )
        XCTAssertFalse(viewModel.hasPendingInteraction(forConversationID: firstConversation.id))
    }

    func testPendingApprovalIsScopedToItsConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let approvalConversation = viewModel.activeConversation!
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let approvalID = viewModel.activePendingApproval!.id

        _ = viewModel.createConversation(for: agent)
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertNil(viewModel.sendTask)

        viewModel.allowPendingApprovalOnce(id: approvalID)
        XCTAssertTrue(transport.approvalDecisions.isEmpty)
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: approvalConversation.id))

        viewModel.selectConversation(approvalConversation)
        XCTAssertEqual(viewModel.activePendingApproval?.id, approvalID)
        viewModel.allowPendingApprovalOnce(id: approvalID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
    }

    func testAskUserAnswerResumesTheActiveAgentTurn() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.askUserRequests = [
            AskUserRequest(
                id: "question-1",
                question: "Which environment?",
                options: ["Staging", "Production"]
            )
        ]

        viewModel.prompt = "Deploy the app"
        viewModel.sendPrompt()
        await waitForPendingAskUser(on: viewModel)

        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertEqual(viewModel.activePendingAskUser?.request.question, "Which environment?")

        viewModel.answerPendingAskUser(id: "question-1", answer: "Staging")
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.askUserAnswers, ["Staging"])
        XCTAssertNil(viewModel.activePendingAskUser)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testStoppingPendingAskUserCancelsWithoutSubmittingEmptyAnswer() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.askUserRequests = [
            AskUserRequest(id: "question-1", question: "Continue?", options: ["Yes", "No"])
        ]
        transport.waitAfterInteractionsUntilCancelled = true

        viewModel.prompt = "Start task"
        viewModel.sendPrompt()
        await waitForPendingAskUser(on: viewModel)
        let task = viewModel.sendTask

        viewModel.stopActiveResponse()
        await task?.value

        XCTAssertEqual(transport.askUserDecisions, [.cancel])
        XCTAssertTrue(transport.askUserAnswers.isEmpty)
        XCTAssertNil(viewModel.activePendingAskUser)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testDeletingConversationCancelsAskUserWithoutSubmittingEmptyAnswer() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let conversation = viewModel.activeConversation!
        transport.askUserRequests = [
            AskUserRequest(id: "question-1", question: "Continue?", options: ["Yes", "No"])
        ]
        transport.waitAfterInteractionsUntilCancelled = true

        viewModel.prompt = "Start task"
        viewModel.sendPrompt()
        await waitForPendingAskUser(on: viewModel)
        let task = viewModel.sendTask

        viewModel.deleteConversation(conversation)
        await task?.value

        XCTAssertEqual(transport.askUserDecisions, [.cancel])
        XCTAssertTrue(transport.askUserAnswers.isEmpty)
        XCTAssertNil(viewModel.activePendingAskUser)
        XCTAssertNil(viewModel.conversation(withID: conversation.id))
    }

    func testPendingAskUserIsScopedToItsConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let questionConversation = viewModel.activeConversation!
        transport.askUserRequests = [
            AskUserRequest(id: "question-1", question: "Continue?", options: ["Yes", "No"])
        ]

        viewModel.prompt = "Start task"
        viewModel.sendPrompt()
        await waitForPendingAskUser(on: viewModel)

        _ = viewModel.createConversation(for: agent)
        XCTAssertNil(viewModel.activePendingAskUser)

        viewModel.answerPendingAskUser(id: "question-1", answer: "Yes")
        XCTAssertTrue(transport.askUserAnswers.isEmpty)
        XCTAssertNil(viewModel.activePendingAskUser)
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: questionConversation.id))
        XCTAssertTrue(viewModel.hasBackgroundPendingInteraction)

        viewModel.selectConversation(questionConversation)
        viewModel.answerPendingAskUser(id: "question-1", answer: "Yes")
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.askUserAnswers, ["Yes"])
        XCTAssertNil(viewModel.activePendingAskUser)
    }

    func testApprovalGateRegistersBeforePresentation() async {
        let gate = ContinuationGate<ApprovalDecision>(
            cancellationDecision: .rejectHard(feedback: "cancelled"),
            unavailableDecision: .rejectHard(feedback: "unavailable")
        )
        var dismissed = false

        let decision = await gate.wait(for: "approval") {
            XCTAssertTrue(gate.resolve(id: "approval", with: .allowOnce))
            return true
        } dismiss: {
            dismissed = true
        }

        XCTAssertEqual(decision, .allowOnce)
        XCTAssertTrue(dismissed)
    }

    func testDeletingConversationCancelsPendingApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let conversation = viewModel.activeConversation!
        let task = viewModel.sendTask
        viewModel.deleteConversation(conversation)
        await task?.value

        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertNil(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
    }

    func testEveryModeWaitsForUserApproval() async {
        for mode in ChatMode.allCases {
            let (viewModel, transport, _) = makeEnvironment()
            setUpAgentAndConversation(viewModel)
            viewModel.setMode(mode)
            transport.approvalRequests = [approvalRequest(tool: "credit_card_charge")]

            viewModel.prompt = "Charge the card"
            viewModel.sendPrompt()
            await waitForPendingApproval(on: viewModel)

            XCTAssertEqual(viewModel.activePendingApproval?.request.tool, "credit_card_charge")
            XCTAssertTrue(transport.approvalDecisions.isEmpty, "\(mode.label) resolved approval automatically")

            viewModel.skipPendingApproval(id: viewModel.activePendingApproval!.id)
            await viewModel.sendTask?.value
            XCTAssertEqual(transport.approvalDecisions, [.rejectSoft(feedback: nil)])
        }
    }

    func testSelectingUlwDoesNotForgeServerOwnedCapabilityState() {
        let (viewModel, _, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        // Floored: the signed payload carries whole seconds so CanonicalJSON stays
        // byte-identical to the Python/TS reference implementations.
        let selectedAt = Date().timeIntervalSince1970.rounded(.down)

        viewModel.setMode(.ulw)

        let session = viewModel.activeConversation?.serverSession
        XCTAssertEqual(session?["mode"], .string("ulw"))
        XCTAssertNil(session?["skip_tool_approval"])
        XCTAssertNil(session?["ulw_turns"])
        XCTAssertNil(session?["ulw_turns_used"])
        let updated = session?["updated"]?.numberValue ?? 0
        XCTAssertGreaterThanOrEqual(updated, selectedAt)
        XCTAssertEqual(updated, updated.rounded(.down))
    }

    func testLeavingUlwClearsAutonomousSessionState() {
        let (viewModel, _, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        var conversation = viewModel.activeConversation!
        conversation.serverSession?["skip_tool_approval"] = .bool(true)
        viewModel.upsertForTesting(conversation)

        viewModel.setMode(.safe)

        let session = viewModel.activeConversation?.serverSession
        XCTAssertEqual(session?["mode"], .string("safe"))
        XCTAssertNil(session?["ulw_turns"])
        XCTAssertNil(session?["ulw_turns_used"])
        XCTAssertNil(session?["skip_tool_approval"])
    }

    func testServerModeChangedEventEndsUlwLocally() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        transport.streamedEvents = [.modeChanged(.safe)]

        viewModel.prompt = "Keep working"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        XCTAssertEqual(viewModel.activeMode, .safe)
        XCTAssertEqual(viewModel.activeConversation?.serverSession?["mode"], .string("safe"))
    }

    func testApprovalSupportsStopAndExplain() async {
        for expected in [
            ApprovalDecision.rejectHard(feedback: nil),
            ApprovalDecision.rejectExplain(feedback: nil)
        ] {
            let (viewModel, transport, _) = makeEnvironment()
            setUpAgentAndConversation(viewModel)
            transport.approvalRequests = [approvalRequest(tool: "bash")]

            viewModel.prompt = "Run a command"
            viewModel.sendPrompt()
            await waitForPendingApproval(on: viewModel)
            let id = viewModel.activePendingApproval!.id
            if expected == .rejectHard(feedback: nil) {
                viewModel.stopPendingApproval(id: id)
            } else {
                viewModel.explainPendingApproval(id: id)
            }
            await viewModel.sendTask?.value

            XCTAssertEqual(transport.approvalDecisions, [expected])
            XCTAssertTrue(transport.interactionResponseWaits.isEmpty)
        }
    }

    func testUlwCheckpointWaitsForContinueDecision() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        transport.ulwCheckpoints = [UlwCheckpointRequest(turnsUsed: 100, maxTurns: 100)]

        viewModel.prompt = "Keep working"
        viewModel.sendPrompt()
        await waitForUlwCheckpoint(on: viewModel)
        XCTAssertTrue(transport.ulwDecisions.isEmpty)

        viewModel.continueUlw(id: viewModel.activePendingUlwCheckpoint!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.ulwDecisions, [.continueWork(turns: 100)])
        XCTAssertEqual(viewModel.activeMode, .ulw)
    }

    func testUlwCheckpointCanSwitchToAcceptEdits() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        transport.ulwCheckpoints = [UlwCheckpointRequest(turnsUsed: 100, maxTurns: 100)]

        viewModel.prompt = "Keep working"
        viewModel.sendPrompt()
        await waitForUlwCheckpoint(on: viewModel)
        viewModel.switchModeFromUlwCheckpoint(id: viewModel.activePendingUlwCheckpoint!.id, to: .accept)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.ulwDecisions, [.switchMode(.accept)])
        XCTAssertEqual(viewModel.activeMode, .accept)
    }

    func testPlanReviewWaitsForApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.plan)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        XCTAssertTrue(transport.planReviewDecisions.isEmpty)

        viewModel.approvePendingPlan(id: viewModel.activePendingPlanReview!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.planReviewDecisions, [.approve])
    }

    func testPlanReviewSendsRevisionFeedback() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        viewModel.requestPlanChanges(
            id: viewModel.activePendingPlanReview!.id,
            feedback: "Use smaller commits"
        )
        await viewModel.sendTask?.value

        XCTAssertEqual(
            transport.planReviewDecisions,
            [.requestChanges(feedback: "Use smaller commits")]
        )
    }

    func testStoppingPendingPlanReviewWaitsForResponseBeforeCancelling() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]
        transport.waitAfterInteractionsUntilCancelled = true

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        let conversationID = viewModel.activeConversation!.id
        let task = viewModel.sendTask

        viewModel.stopActiveResponse()
        await task?.value

        XCTAssertEqual(
            transport.planReviewDecisions,
            [.requestChanges(feedback: "Plan review cancelled.")]
        )
        XCTAssertEqual(transport.interactionResponseWaits.count, 1)
        XCTAssertEqual(transport.interactionResponseWaits.first?.conversationID, conversationID)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testPendingPlanReviewIsScopedToItsConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let reviewConversation = viewModel.activeConversation!
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        let reviewID = viewModel.activePendingPlanReview!.id

        _ = viewModel.createConversation(for: agent)
        XCTAssertNil(viewModel.activePendingPlanReview)
        XCTAssertNil(viewModel.activePendingPlanReview)
        XCTAssertNil(viewModel.sendTask)

        viewModel.approvePendingPlan(id: reviewID)
        XCTAssertTrue(transport.planReviewDecisions.isEmpty)
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: reviewConversation.id))

        viewModel.selectConversation(reviewConversation)
        XCTAssertEqual(viewModel.activePendingPlanReview?.id, reviewID)
        viewModel.approvePendingPlan(id: reviewID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.planReviewDecisions, [.approve])
    }

    func testDeletingConversationCancelsUlwCheckpoint() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.ulwCheckpoints = [UlwCheckpointRequest(turnsUsed: 100, maxTurns: 100)]

        viewModel.prompt = "Keep working"
        viewModel.sendPrompt()
        await waitForUlwCheckpoint(on: viewModel)
        let conversation = viewModel.activeConversation!
        let task = viewModel.sendTask
        viewModel.deleteConversation(conversation)
        await task?.value

        XCTAssertNil(viewModel.activePendingUlwCheckpoint)
        XCTAssertEqual(transport.ulwDecisions, [.switchMode(.safe)])
    }

    func testDeletingConversationCancelsPlanReview() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        let conversation = viewModel.activeConversation!
        let task = viewModel.sendTask
        viewModel.deleteConversation(conversation)
        await task?.value

        XCTAssertNil(viewModel.activePendingPlanReview)
        XCTAssertEqual(
            transport.planReviewDecisions,
            [.requestChanges(feedback: "Plan review cancelled.")]
        )
    }

    func testDeletingAgentCancelsPendingApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let task = viewModel.sendTask
        viewModel.deleteAgent(agent)
        await task?.value

        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
    }

    func testCancellingSendTaskCancelsPendingApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        viewModel.sendTask?.cancel()
        await viewModel.sendTask?.value

        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
    }

    func testViewModelTeardownCancelsPendingApproval() async {
        let store = try! SwiftDataConversationRepository(inMemory: true, defaults: makeDefaults())
        let transport = MockAgentTransport()
        let monitor = MockNetworkMonitor()
        var viewModel: ChatViewModel? = ChatViewModel(store: store, client: transport, networkMonitor: monitor)
        // `weak var`, not `weak let`: Swift 6 accepts the latter, Swift 5 rejects it
        // outright, and the reference is never reassigned either way.
        weak var releasedViewModel = viewModel
        setUpAgentAndConversation(viewModel!)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel?.prompt = "Create a file"
        viewModel?.sendPrompt()
        await waitForPendingApproval(on: viewModel!)
        viewModel = nil
        for _ in 0..<100 where releasedViewModel != nil {
            await Task.yield()
        }
        for _ in 0..<100 where transport.approvalDecisions.isEmpty {
            await Task.yield()
        }

        XCTAssertNil(releasedViewModel)
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
    }

    // offline banner dismissal and manual retry
    func testOfflineBannerDismissalResetsOnNextDrop() {
        let (viewModel, _, monitor) = makeEnvironment()

        monitor.simulate(online: false)
        XCTAssertTrue(viewModel.shouldShowOfflineBanner)

        viewModel.dismissOfflineBanner()
        XCTAssertFalse(viewModel.shouldShowOfflineBanner)
        XCTAssertTrue(viewModel.isOffline, "dismissing the banner must not clear the offline state")

        monitor.simulate(online: true)
        monitor.simulate(online: false)
        XCTAssertTrue(viewModel.shouldShowOfflineBanner, "a fresh drop should show the banner again")
    }

    func testRetryConnectivityRecoversWithoutMonitorUpdate() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)
        viewModel.prompt = "stuck in queue"
        viewModel.sendPrompt()

        viewModel.retryConnectivity()
        await viewModel.recoveryTask?.value

        XCTAssertFalse(viewModel.isOffline, "successful reconnect should clear offline even if the monitor is stale")
        XCTAssertEqual(transport.connectedAddresses, [address])
        XCTAssertEqual(transport.sentPrompts, ["stuck in queue"])
        XCTAssertEqual(viewModel.connectionState, .connected)
    }

    func testRetryConnectivityStaysOfflineWhenReconnectFails() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.connectBehavior = .fail(HostedAgentClientError.timeout)
        monitor.simulate(online: false)
        viewModel.prompt = "still stuck"
        viewModel.sendPrompt()

        viewModel.retryConnectivity()
        await viewModel.recoveryTask?.value

        XCTAssertTrue(viewModel.isOffline)
        XCTAssertTrue(viewModel.shouldShowOfflineBanner)
        XCTAssertTrue(transport.sentPrompts.isEmpty, "queue must not flush when reconnect fails")
    }

    func testRetryConnectivityIgnoredWhenOnline() {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)

        viewModel.retryConnectivity()

        XCTAssertNil(viewModel.recoveryTask)
        XCTAssertTrue(transport.connectedAddresses.isEmpty)
    }

    // background probing while offline
    func testProbeAutoSendsQueueWithoutMonitorOrManualRetry() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.probeInterval = 0.01
        transport.connectBehavior = .fail(HostedAgentClientError.timeout)
        monitor.simulate(online: false)
        viewModel.prompt = "auto delivered"
        viewModel.sendPrompt()

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isOffline, "failing probes must not flip the app online")
        XCTAssertNil(viewModel.errorMessage, "failing probes must stay silent")
        XCTAssertTrue(transport.sentPrompts.isEmpty)

        transport.connectBehavior = .succeed(output: "")
        await viewModel.probeTask?.value

        XCTAssertFalse(viewModel.isOffline)
        XCTAssertEqual(viewModel.connectionState, .connected)
        XCTAssertEqual(transport.sentPrompts, ["auto delivered"])
        let userMessage = (viewModel.activeConversation?.messages ?? []).last { $0.role == .user }
        XCTAssertEqual(userMessage?.deliveryState, .sent)
    }

    func testLosingTheNetworkClosesTheTransportsSockets() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)

        monitor.simulate(online: false)
        await viewModel.disconnectTask?.value

        XCTAssertEqual(
            transport.networkLossNotices,
            1,
            "a socket left believing it is connected makes every later probe answer from cache"
        )
    }

    func testProbeReconnectRunsAfterTheSocketsAreClosed() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.probeInterval = 0.01
        monitor.simulate(online: false)

        await viewModel.probeTask?.value

        XCTAssertEqual(transport.networkLossNotices, 1)
        XCTAssertEqual(transport.connectedAddresses, [address], "the probe must open a fresh connection")
        XCTAssertFalse(viewModel.isOffline)
    }

    // the reported flow: drop the network, wait through a few probe cycles, then send
    func testSendingWhileOfflineQueuesAndNeverLooksLikeWork() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.probeInterval = 0.01
        transport.connectBehavior = .fail(HostedAgentClientError.closed)
        monitor.simulate(online: false)
        try? await Task.sleep(nanoseconds: 50_000_000)

        viewModel.prompt = "typed while offline"
        viewModel.sendPrompt()

        XCTAssertTrue(viewModel.shouldShowOfflineBanner, "probes that cannot connect must not clear the banner")
        XCTAssertTrue(transport.sentPrompts.isEmpty)
        XCTAssertFalse(viewModel.isProcessing, "nothing is in flight, so the agent is not working")
        let messages = viewModel.activeConversation?.messages ?? []
        XCTAssertEqual(messages.last { $0.role == .user }?.deliveryState, .queued)
        XCTAssertFalse(messages.contains { $0.role == .thinking })
    }

    func testProbingStopsWhenMonitorReportsOnline() {
        let (viewModel, _, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)

        monitor.simulate(online: false)
        XCTAssertNotNil(viewModel.probeTask)

        monitor.simulate(online: true)
        XCTAssertTrue(viewModel.probeTask?.isCancelled ?? false)
    }

    /// A second request of the same kind means the agent moved on from the first. Its gate has
    /// to be released or the receive loop blocks forever, but nothing may be written back for
    /// it — response frames carry no request ID, so a late reply reads as an answer to the
    /// request that replaced it.
    func testSupersededInteractionReleasesItsGateWithoutAnswering() async {
        let coordinator = InteractionCoordinator()
        let first = ToolApprovalRequest(id: "ap-1", tool: "write", arguments: [:])
        let second = ToolApprovalRequest(id: "ap-2", tool: "write", arguments: [:])

        async let firstDecision = coordinator.handle(.approval(first), conversationID: "c1") { true }
        for _ in 0..<100 where coordinator.pendingApproval(for: "c1")?.id != "ap-1" {
            await Task.yield()
        }

        async let secondDecision = coordinator.handle(.approval(second), conversationID: "c1") { true }
        for _ in 0..<100 where coordinator.pendingApproval(for: "c1")?.id != "ap-2" {
            await Task.yield()
        }
        coordinator.resolve(id: "ap-2", conversationID: "c1", with: .approval(.allowOnce))

        let decisions = await (firstDecision, secondDecision)
        XCTAssertEqual(decisions.0, .superseded)
        XCTAssertEqual(decisions.1, .approval(.allowOnce))
    }

    func testFailedSendInBackgroundConversationSurfacesOnSidebarAffordance() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let failing = viewModel.activeConversation!
        transport.sendBehavior = .fail(HostedAgentClientError.closed)

        viewModel.prompt = "Run it"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        XCTAssertTrue(viewModel.hasFailedDelivery(forConversationID: failing.id))
        XCTAssertEqual(viewModel.activityState(forConversationID: failing.id), .failedDelivery)
        XCTAssertFalse(viewModel.hasBackgroundDeliveryFailure, "failure is in the active conversation")
        XCTAssertNil(viewModel.backgroundActivityState)

        _ = viewModel.createConversation(for: agent)

        XCTAssertTrue(viewModel.hasBackgroundDeliveryFailure)
        XCTAssertTrue(viewModel.needsBackgroundAttention)
        XCTAssertEqual(viewModel.backgroundActivityState, .failedDelivery)

        viewModel.deleteConversation(failing)
        XCTAssertFalse(viewModel.hasBackgroundDeliveryFailure)
        XCTAssertNil(viewModel.backgroundActivityState)
    }

    private func makeEnvironment() -> (ChatViewModel, MockAgentTransport, MockNetworkMonitor) {
        let store = try! SwiftDataConversationRepository(inMemory: true, defaults: makeDefaults())
        let transport = MockAgentTransport()
        let monitor = MockNetworkMonitor()
        let viewModel = ChatViewModel(store: store, client: transport, networkMonitor: monitor)
        return (viewModel, transport, monitor)
    }

    func testSlashPickerLoadsSortsAndFiltersServerSkills() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.availableSkills = [
            AgentSkill(name: "Review", description: "Review current changes"),
            AgentSkill(name: "commit", description: "Create a commit"),
            AgentSkill(name: "release", description: "Prepare a release")
        ]

        viewModel.prompt = "/"
        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport)

        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["commit", "release", "Review"])
        XCTAssertTrue(viewModel.shouldShowSlashSkillPicker)

        viewModel.prompt = "/RE"
        viewModel.promptDidChange()
        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["release", "Review"])

        viewModel.prompt = "/review details"
        viewModel.promptDidChange()
        XCTAssertTrue(viewModel.slashSkillSuggestions.isEmpty)
        XCTAssertFalse(viewModel.shouldShowSlashSkillPicker)
        XCTAssertEqual(transport.fetchedSkillAddresses.count, 1)
    }

    func testSkillLoadingPublishesThroughViewModelFacade() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.availableSkills = [AgentSkill(name: "review")]
        viewModel.prompt = "/"
        var didPublish = false
        let cancellable = viewModel.objectWillChange.sink {
            didPublish = true
        }

        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport)

        XCTAssertTrue(didPublish)
        withExtendedLifetime(cancellable) {}
    }

    func testSelectingSlashSkillInsertsCommandWithArgumentSpace() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.availableSkills = [AgentSkill(name: "commit", description: "Create a commit")]
        viewModel.prompt = "/"
        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport)

        viewModel.selectSlashSkill(viewModel.slashSkillSuggestions[0])

        XCTAssertEqual(viewModel.prompt, "/commit ")
        XCTAssertFalse(viewModel.shouldShowSlashSkillPicker)
    }

    func testSlashDiscoveryFailureKeepsRawCommandSendable() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.skillFetchError = HostedAgentClientError.server("metadata unavailable")
        viewModel.prompt = "/unknown"
        viewModel.promptDidChange()
        await waitForSkillFetchAttempt(transport: transport)

        XCTAssertFalse(viewModel.shouldShowSlashSkillPicker)
        XCTAssertNil(viewModel.errorMessage)

        viewModel.sendPrompt()
        await waitForSentPrompt(transport: transport)
        XCTAssertEqual(transport.sentPrompts, ["/unknown"])
    }

    func testSlashSuggestionsFollowActiveAgentWithoutStaleResults() async {
        let (viewModel, transport, _) = makeEnvironment()
        let first = setUpAgentAndConversation(viewModel)
        let secondAddress = "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        let second = viewModel.saveAgent(name: "Second", address: secondAddress)!
        _ = viewModel.createConversation(for: second)
        transport.skillsByAddress = [
            first.address: [AgentSkill(name: "first")],
            second.address: [AgentSkill(name: "second")]
        ]

        viewModel.prompt = "/"
        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport)
        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["second"])

        viewModel.selectAgent(first)
        XCTAssertTrue(viewModel.prompt.isEmpty)
        viewModel.prompt = "/"
        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport, address: first.address)
        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["first"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func approvalRequest(tool: String) -> ToolApprovalRequest {
        ToolApprovalRequest(
            id: "approval-\(tool)",
            tool: tool,
            arguments: ["path": .string("prompt.md")]
        )
    }

    private func waitForPendingApproval(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.activePendingApproval == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.activePendingApproval)
    }

    private func waitForActivePendingApproval(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.activePendingApproval == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.activePendingApproval)
    }

    private func waitForUlwCheckpoint(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.activePendingUlwCheckpoint == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.activePendingUlwCheckpoint)
    }

    private func waitForPendingAskUser(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.activePendingAskUser == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.activePendingAskUser)
    }

    private func waitForPlanReview(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.activePendingPlanReview == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.activePendingPlanReview)
    }

    private func waitForSkillFetch(
        on viewModel: ChatViewModel,
        transport: MockAgentTransport,
        address: String? = nil
    ) async {
        for _ in 0..<100 {
            if let address {
                if transport.fetchedSkillAddresses.contains(address), !viewModel.slashSkillSuggestions.isEmpty {
                    return
                }
            } else if !transport.fetchedSkillAddresses.isEmpty, !viewModel.slashSkillSuggestions.isEmpty {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for slash skills")
    }

    private func waitForSkillFetchAttempt(transport: MockAgentTransport) async {
        for _ in 0..<100 where transport.fetchedSkillAddresses.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(transport.fetchedSkillAddresses.isEmpty)
    }

    private func waitForSentPrompt(transport: MockAgentTransport) async {
        for _ in 0..<100 where transport.sentPrompts.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(transport.sentPrompts.isEmpty)
    }

    private func waitForSentPrompt(_ prompt: String, transport: MockAgentTransport) async {
        for _ in 0..<100 where !transport.sentPrompts.contains(prompt) {
            await Task.yield()
        }
        XCTAssertTrue(transport.sentPrompts.contains(prompt))
    }

    private func waitUntilIdle(_ conversationID: String, on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.isProcessing(conversationID: conversationID) {
            await Task.yield()
        }
        XCTAssertFalse(viewModel.isProcessing(conversationID: conversationID))
    }

    @discardableResult
    private func setUpAgentAndConversation(_ viewModel: ChatViewModel) -> SavedAgent {
        let agent = viewModel.saveAgent(name: "Recovery Agent", address: address)!
        _ = viewModel.createConversation(for: agent)
        return agent
    }
}
