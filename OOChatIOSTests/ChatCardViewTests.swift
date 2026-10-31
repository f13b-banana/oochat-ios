import SwiftUI
import XCTest
@testable import OOChatIOS

@MainActor
final class PlanReviewCardTests: XCTestCase {
    private func makeReview(plan: String = "1. Do the thing") -> PendingPlanReview {
        PendingPlanReview(conversationID: "con1", request: PlanReviewRequest(id: "plan1", planContent: plan))
    }

    func testApproveButtonInvokesCallback() {
        var approved = false
        let card = PlanReviewCard(
            review: makeReview(),
            onApprove: { approved = true },
            onRequestChanges: { _ in XCTFail("unexpected request-changes") }
        )
        let window = ViewHost.host(card)

        XCTAssertTrue(ViewHost.activate(identifier: "plan.approve.plan1", in: window))
        XCTAssertTrue(approved)
    }

    func testRequestChangesInvokesCallbackWithFeedback() {
        var feedback: String??
        let card = PlanReviewCard(
            review: makeReview(),
            onApprove: { XCTFail("unexpected approve") },
            onRequestChanges: { feedback = $0 }
        )
        let window = ViewHost.host(card)

        XCTAssertTrue(ViewHost.activate(identifier: "plan.requestChanges.plan1", in: window))
        XCTAssertEqual(feedback, .some(""))
    }
}

@MainActor
final class MessageBubbleTests: XCTestCase {
    private func message(
        role: ChatRole,
        content: String = "Hello",
        delivery: MessageDeliveryState = .sent
    ) -> ChatMessage {
        ChatMessage(id: "msg1", role: role, content: content, deliveryState: delivery)
    }

    func testRendersEveryRole() {
        for role in [ChatRole.user, .agent, .thinking, .tool, .error] {
            let window = ViewHost.host(MessageBubble(message: message(role: role)))
            XCTAssertNotNil(window.rootViewController?.view)
        }
    }

    func testThinkingIndicatorAnimatesAndHandlesEmptyText() {
        _ = ViewHost.host(MessageBubble(message: message(role: .thinking, content: "Pondering")))
        ViewHost.pump(0.3)

        _ = ViewHost.host(MessageBubble(message: message(role: .thinking, content: "")))
        ViewHost.pump(0.3)
    }

    func testQueuedDeliveryShowsQueuedBadge() {
        let window = ViewHost.host(MessageBubble(message: message(role: .user, delivery: .queued)))
        XCTAssertNotNil(ViewHost.element(labelContains: "Queued", in: window))
    }

    func testPhotoThumbnailOpensFullScreenPreview() {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let photoMessage = ChatMessage(
            id: "photo-message",
            role: .user,
            content: "",
            images: [ChatImageAttachment(id: "photo-1", data: png, mimeType: "image/png")]
        )
        let window = ViewHost.host(MessageBubble(message: photoMessage))

        XCTAssertTrue(ViewHost.activate(labelContains: "View photo 1 full screen", in: window))
        ViewHost.pump(0.4)

        XCTAssertNotNil(
            ViewHost.waitForElement(labelContains: "Full size photo", in: window)
        )
        XCTAssertTrue(ViewHost.activate(labelContains: "Close photo", in: window))
    }

    func testFileAttachmentShowsDownloadAction() {
        let fileMessage = ChatMessage(
            id: "file-message",
            role: .user,
            content: "",
            files: [
                ChatFileAttachment(
                    id: "file-1",
                    name: "notes.txt",
                    data: Data("hello".utf8),
                    mimeType: "text/plain"
                )
            ]
        )
        let window = ViewHost.host(MessageBubble(message: fileMessage))

        XCTAssertNotNil(ViewHost.element(labelContains: "Download file notes.txt", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Download file notes.txt", in: window))
    }

    func testFailedDeliveryRetryInvokesCallback() {
        var retried = false
        let bubble = MessageBubble(message: message(role: .user, delivery: .failed)) {
            retried = true
        }
        let window = ViewHost.host(bubble)

        XCTAssertTrue(ViewHost.activate(labelContains: "Retry sending message", in: window))
        XCTAssertTrue(retried)
    }

    func testCancelledDeliveryRetryInvokesCallback() {
        var retried = false
        let bubble = MessageBubble(message: message(role: .user, delivery: .cancelled)) {
            retried = true
        }
        let window = ViewHost.host(bubble)

        XCTAssertTrue(ViewHost.activate(labelContains: "Retry cancelled message", in: window))
        XCTAssertTrue(retried)
    }
}

@MainActor
final class UlwCheckpointCardTests: XCTestCase {
    private func makeCheckpoint() -> PendingUlwCheckpoint {
        PendingUlwCheckpoint(
            conversationID: "con1",
            request: UlwCheckpointRequest(id: "ulw1", turnsUsed: 100, maxTurns: 100)
        )
    }

    func testAllThreeActionsInvokeCallbacks() {
        var taps: [String] = []
        let card = UlwCheckpointCard(
            checkpoint: makeCheckpoint(),
            onContinue: { taps.append("continue") },
            onAcceptEdits: { taps.append("accept") },
            onSafeMode: { taps.append("safe") }
        )
        let window = ViewHost.host(card)

        XCTAssertTrue(ViewHost.activate(identifier: "ulw.continue.ulw1", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "ulw.acceptEdits.ulw1", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "ulw.safe.ulw1", in: window))
        XCTAssertEqual(taps, ["continue", "accept", "safe"])
    }
}

@MainActor
final class AskUserCardTests: XCTestCase {
    private func pending(_ request: AskUserRequest) -> PendingAskUser {
        PendingAskUser(conversationID: "con1", request: request)
    }

    func testSingleSelectSubmitsTappedOption() {
        var answer: String?
        let request = AskUserRequest(id: "ask1", question: "Pick one", options: ["Red", "Blue"])
        let window = ViewHost.host(AskUserCard(pending: pending(request)) { answer = $0 })

        XCTAssertTrue(ViewHost.activate(identifier: "askUser.option.ask1.1", in: window))
        XCTAssertEqual(answer, "Blue")
    }

    func testMultiSelecttogglesAndSubmitsInOptionOrder() {
        var answer: String?
        let request = AskUserRequest(
            id: "ask2",
            question: "Pick some",
            options: ["Red", "Blue", "Green"],
            multiSelect: true
        )
        let window = ViewHost.host(AskUserCard(pending: pending(request)) { answer = $0 })

        XCTAssertTrue(ViewHost.activate(identifier: "askUser.multiOption.ask2.2", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "askUser.multiOption.ask2.0", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "askUser.multiOption.ask2.2", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "askUser.multiOption.ask2.2", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "askUser.submit.ask2", in: window))
        XCTAssertEqual(answer, "Red, Green")
    }

    func testMultiSelectSubmitDisabledWithoutSelection() {
        var answer: String?
        let request = AskUserRequest(id: "ask3", question: "Pick some", options: ["Red"], multiSelect: true)
        let window = ViewHost.host(AskUserCard(pending: pending(request)) { answer = $0 })

        ViewHost.activate(identifier: "askUser.submit.ask3", in: window)
        XCTAssertNil(answer)
    }

    func testFreeTextFormRendersWithDisabledSubmit() {
        var answer: String?
        let request = AskUserRequest(id: "ask4", question: "Say anything")
        let window = ViewHost.host(AskUserCard(pending: pending(request)) { answer = $0 })

        XCTAssertNotNil(ViewHost.element(identifier: "askUser.freeText.ask4", in: window))
        ViewHost.activate(identifier: "askUser.submit.ask4", in: window)
        XCTAssertNil(answer)
    }

    func testFieldFormRendersSecureAndPlainFields() {
        let request = AskUserRequest(
            id: "ask5",
            question: "Credentials",
            fields: [
                AskUserField(name: "user", label: "Username", placeholder: "you@example.com"),
                AskUserField(name: "pass", label: "Password", type: "password")
            ]
        )
        let window = ViewHost.host(AskUserCard(pending: pending(request)) { _ in })

        XCTAssertNotNil(ViewHost.element(identifier: "askUser.field.ask5.user", in: window))
        XCTAssertNotNil(ViewHost.element(identifier: "askUser.field.ask5.pass", in: window))
        ViewHost.activate(identifier: "askUser.submit.ask5", in: window)
    }
}

@MainActor
final class ApprovalCardTests: XCTestCase {
    private var receivedActions: [String] = []

    override func setUp() {
        super.setUp()
        receivedActions = []
    }

    private func makeCard(request: ToolApprovalRequest) -> ApprovalCard {
        ApprovalCard(
            approval: PendingApproval(conversationID: "con1", request: request),
            onAllowOnce: { self.receivedActions.append("allow") },
            onTrustSession: { self.receivedActions.append("trust") },
            onSkip: { self.receivedActions.append("skip") },
            onStop: { self.receivedActions.append("stop") },
            onExplain: { self.receivedActions.append("explain") }
        )
    }

    func testCommandRequestExpandsAndFiresAllActions() {
        let request = ToolApprovalRequest(
            id: "appr1",
            tool: "run_command",
            arguments: [
                "cmd": .string("ls -la"),
                "cwd": .string("/tmp")
            ],
            description: "Lists the directory",
            batchRemaining: [ToolApprovalBatchItem(tool: "read_file")]
        )
        let window = ViewHost.host(makeCard(request: request))

        XCTAssertTrue(ViewHost.activate(labelContains: "Command", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Command", in: window))

        XCTAssertTrue(ViewHost.activate(identifier: "approval.allowOnce.appr1", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "approval.trustSession.appr1", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "approval.skip.appr1", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "approval.stop.appr1", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "approval.explain.appr1", in: window))
        XCTAssertEqual(receivedActions, ["allow", "trust", "skip", "stop", "explain"])
    }

    func testLongCommandUsesGenericTrustTitle() {
        let request = ToolApprovalRequest(
            id: "appr2",
            tool: "run_command",
            arguments: ["command": .string("find / -name something-very-long -print0")]
        )
        let window = ViewHost.host(makeCard(request: request))
        XCTAssertNotNil(ViewHost.element(labelContains: "Trust this command", in: window))
    }

    func testNonCommandRequestShowsToolNameAndPathSubtitle() {
        let request = ToolApprovalRequest(
            id: "appr3",
            tool: "write_file",
            arguments: ["path": .string("/tmp/out.txt"), "content": .string("hi")]
        )
        let window = ViewHost.host(makeCard(request: request))

        XCTAssertNotNil(ViewHost.element(labelContains: "Write File", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Trust this tool", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "approval.allowOnce.appr3", in: window))
        XCTAssertEqual(receivedActions, ["allow"])
    }

    func testUrlSubtitleFallbackAndScriptCommand() {
        let urlRequest = ToolApprovalRequest(
            id: "appr4",
            tool: "fetch",
            arguments: ["url": .string("https://example.com")]
        )
        _ = ViewHost.host(makeCard(request: urlRequest))

        let scriptRequest = ToolApprovalRequest(
            id: "appr5",
            tool: "run_script",
            arguments: ["script": .string("echo hi")]
        )
        let window = ViewHost.host(makeCard(request: scriptRequest))
        XCTAssertNotNil(ViewHost.element(labelContains: "Trust echo hi", in: window))
    }
}

@MainActor
final class MarkdownMessageViewRenderTests: XCTestCase {
    func testRendersPlainMarkdown() {
        let window = ViewHost.host(MarkdownMessageView(content: "**Bold** and _italic_ text"))
        XCTAssertNotNil(window.rootViewController?.view)
    }

    func testCodeBlockShowsLanguageLabelAndCopies() {
        let content = """
        Intro

        ```swift
        let x = 1
        ```
        """
        let window = ViewHost.host(MarkdownMessageView(content: content))
        ViewHost.pump(0.3)

        UIPasteboard.general.string = ""
        XCTAssertTrue(ViewHost.activate(labelContains: "Copy code", in: window))
        XCTAssertEqual(UIPasteboard.general.string, "let x = 1")
        XCTAssertNotNil(ViewHost.element(labelContains: "Code copied", in: window))
        ViewHost.pump(1.5)
        XCTAssertNotNil(ViewHost.element(labelContains: "Copy code", in: window))
    }

    func testRepeatedCopyKeepsConfirmationVisibleAfterEarlierReset() {
        let content = """
        ```swift
        let x = 1
        ```
        """
        let window = ViewHost.host(MarkdownMessageView(content: content))
        ViewHost.pump(0.3)

        XCTAssertTrue(ViewHost.activate(labelContains: "Copy code", in: window))
        ViewHost.pump(0.9)
        XCTAssertTrue(ViewHost.activate(labelContains: "Code copied", in: window))
        ViewHost.pump(0.5)

        XCTAssertNotNil(ViewHost.element(labelContains: "Code copied", in: window))
    }

    func testCopyFeedbackResetsAfterCodeBlockLeavesViewport() {
        let content = """
        ```swift
        let x = 1
        ```
        """
        let window = ViewHost.host(MarkdownCopyFeedbackScrollHost(content: content))
        ViewHost.pump(0.3)

        XCTAssertTrue(ViewHost.activate(labelContains: "Copy code", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Scroll away", in: window))
        ViewHost.pump(0.3)
        XCTAssertTrue(ViewHost.activate(labelContains: "Scroll to code", in: window))
        ViewHost.pump(0.3)

        XCTAssertNotNil(ViewHost.element(labelContains: "Copy code", in: window))
    }

    func testCodeBlockWithoutLanguageFallsBackToCodeLabel() {
        let content = """
        ```
        plain block
        ```
        """
        let window = ViewHost.host(MarkdownMessageView(content: content))
        ViewHost.pump(0.3)
        XCTAssertNotNil(ViewHost.element(labelContains: "plain block", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Copy code", in: window))
    }
}

private struct MarkdownCopyFeedbackScrollHost: View {
    let content: String

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 12) {
                HStack {
                    Button("Scroll to code") {
                        proxy.scrollTo("code", anchor: .top)
                    }
                    Button("Scroll away") {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        MarkdownMessageView(content: content)
                            .id("code")
                        Color.clear
                            .frame(height: 2_000)
                            .id("bottom")
                    }
                }
            }
        }
    }
}
