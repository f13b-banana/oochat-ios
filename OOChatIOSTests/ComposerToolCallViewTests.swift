import XCTest
@testable import OOChatIOS

@MainActor
final class ComposerTests: XCTestCase {
    private func makeTransport() -> MockAgentTransport {
        let transport = MockAgentTransport()
        transport.availableSkills = [
            AgentSkill(name: "deploy", description: "Ship the current build"),
            AgentSkill(name: "review", description: "")
        ]
        return transport
    }

    func testRendersWithActiveConversation() {
        let viewModel = ViewFixtures.chatViewModel(transport: makeTransport())
        let window = ViewHost.host(Composer(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Send message", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Chat mode: Safe", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Add attachment", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Start voice input", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Add photos", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Add files", in: window))
    }

    func testAttachmentMenuShowsPhotoAndFileUploadChoices() {
        let viewModel = ViewFixtures.chatViewModel(transport: makeTransport())
        let window = ViewHost.host(Composer(viewModel: viewModel))

        XCTAssertTrue(ViewHost.activate(labelContains: "Add attachment", in: window))
        ViewHost.pump(0.3)

        let windows = [window] + UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        XCTAssertTrue(windows.contains { candidate in
            ViewHost.element(labelContains: "Upload Photo", in: candidate) != nil
        })
        XCTAssertTrue(windows.contains { candidate in
            ViewHost.element(labelContains: "Upload File", in: candidate) != nil
        })
    }

    func testImageOnlyMessageCanBePreviewedRemovedAndSent() {
        let transport = makeTransport()
        let viewModel = ViewFixtures.chatViewModel(transport: transport)
        let window = ViewHost.host(Composer(viewModel: viewModel))
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!

        XCTAssertTrue(viewModel.addPendingImage(data: png, mimeType: "image/png"))
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(labelContains: "Selected photos", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Remove photo 1", in: window))
        XCTAssertTrue(viewModel.pendingImages.isEmpty)

        XCTAssertTrue(viewModel.addPendingImage(data: png, mimeType: "image/png"))
        ViewHost.pump(0.2)
        XCTAssertTrue(ViewHost.activate(labelContains: "Send message", in: window))

        let deadline = Date().addingTimeInterval(3)
        while transport.sentImages.isEmpty && Date() < deadline {
            ViewHost.pump(0.1)
        }
        XCTAssertEqual(transport.sentPrompts, [""])
        XCTAssertEqual(transport.sentImages.first?.first, "data:image/png;base64,\(png.base64EncodedString())")
        XCTAssertTrue(viewModel.pendingImages.isEmpty)
        XCTAssertEqual(viewModel.activeConversation?.messages.first { $0.role == .user }?.images.count, 1)
    }

    func testFileOnlyMessageCanBePreviewedRemovedAndSent() {
        let transport = makeTransport()
        let viewModel = ViewFixtures.chatViewModel(transport: transport)
        let window = ViewHost.host(Composer(viewModel: viewModel))
        let data = Data("hello".utf8)

        XCTAssertTrue(
            viewModel.addPendingFile(
                name: "notes.txt",
                data: data,
                mimeType: "text/plain"
            )
        )
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(labelContains: "Selected files", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Selected file notes.txt", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Remove file 1", in: window))
        XCTAssertTrue(viewModel.pendingFiles.isEmpty)

        XCTAssertTrue(
            viewModel.addPendingFile(
                name: "notes.txt",
                data: data,
                mimeType: "text/plain"
            )
        )
        ViewHost.pump(0.2)
        XCTAssertTrue(ViewHost.activate(labelContains: "Send message", in: window))

        let deadline = Date().addingTimeInterval(3)
        while transport.sentFiles.isEmpty && Date() < deadline {
            ViewHost.pump(0.1)
        }
        XCTAssertEqual(transport.sentPrompts, [""])
        XCTAssertEqual(
            transport.sentFiles.first,
            [
                HostedAgentFilePayload(
                    name: "notes.txt",
                    data: "data:text/plain;base64,\(data.base64EncodedString())"
                )
            ]
        )
        XCTAssertTrue(viewModel.pendingFiles.isEmpty)
        XCTAssertEqual(viewModel.activeConversation?.messages.first { $0.role == .user }?.files.count, 1)
    }

    func testSlashPromptShowsSkillPickerAndSelectionInsertsSkill() {
        let viewModel = ViewFixtures.chatViewModel(transport: makeTransport())
        let window = ViewHost.host(Composer(viewModel: viewModel))
        ViewHost.pump(0.3)

        viewModel.prompt = "/"
        ViewHost.pump(0.3)
        XCTAssertTrue(viewModel.shouldShowSlashSkillPicker)
        XCTAssertNotNil(ViewHost.element(labelContains: "/deploy", in: window))

        XCTAssertTrue(ViewHost.activate(labelContains: "/deploy", in: window))
        XCTAssertTrue(viewModel.prompt.contains("deploy"))
    }

    func testSendButtonSendsPrompt() {
        let transport = makeTransport()
        let viewModel = ViewFixtures.chatViewModel(transport: transport)
        let window = ViewHost.host(Composer(viewModel: viewModel))

        viewModel.prompt = "Hello agent"
        ViewHost.pump(0.2)
        XCTAssertTrue(ViewHost.activate(labelContains: "Send message", in: window))

        let deadline = Date().addingTimeInterval(3)
        while transport.sentPrompts.isEmpty && Date() < deadline {
            ViewHost.pump(0.1)
        }
        XCTAssertEqual(transport.sentPrompts, ["Hello agent"])
    }

    func testVoiceInputButtonStartsAndStopsListening() {
        let transcriber = MockSpeechTranscriber()
        let controller = VoiceInputController(transcriber: transcriber)
        let viewModel = ViewFixtures.chatViewModel(voiceInputController: controller)
        let window = ViewHost.host(Composer(viewModel: viewModel))

        XCTAssertTrue(ViewHost.activate(labelContains: "Start voice input", in: window))
        waitForVoiceInputState(.listening, viewModel: viewModel)
        XCTAssertEqual(transcriber.authorizationRequestCount, 1)
        XCTAssertEqual(transcriber.startCount, 1)
        XCTAssertNotNil(ViewHost.element(labelContains: "Stop voice input", in: window))

        XCTAssertTrue(ViewHost.activate(labelContains: "Stop voice input", in: window))
        XCTAssertEqual(viewModel.voiceInputState, .idle)
        XCTAssertEqual(transcriber.stopCount, 1)
        XCTAssertNotNil(ViewHost.element(labelContains: "Start voice input", in: window))

        XCTAssertTrue(ViewHost.activate(labelContains: "Start voice input", in: window))
        waitForVoiceInputState(.listening, viewModel: viewModel)
        XCTAssertEqual(transcriber.startCount, 2)
        XCTAssertTrue(ViewHost.activate(labelContains: "Stop voice input", in: window))
        XCTAssertEqual(transcriber.stopCount, 2)
    }

    func testVoiceInputPartialsReplaceTranscriptWithoutDuplicatingPrefix() {
        let transcriber = MockSpeechTranscriber()
        let controller = VoiceInputController(transcriber: transcriber)
        let viewModel = ViewFixtures.chatViewModel(voiceInputController: controller)
        let window = ViewHost.host(Composer(viewModel: viewModel))
        viewModel.prompt = "Draft"
        ViewHost.pump()

        XCTAssertTrue(ViewHost.activate(labelContains: "Start voice input", in: window))
        waitForVoiceInputState(.listening, viewModel: viewModel)

        transcriber.emit("hello")
        XCTAssertEqual(viewModel.prompt, "Draft hello")

        transcriber.emit("hello world", isFinal: true)
        XCTAssertEqual(viewModel.prompt, "Draft hello world")
        XCTAssertEqual(viewModel.voiceInputState, .idle)
        ViewHost.pump()
        XCTAssertNotNil(ViewHost.element(labelContains: "Start voice input", in: window))
    }

    func testStoppedVoiceInputIgnoresLateResults() {
        let transcriber = MockSpeechTranscriber()
        let controller = VoiceInputController(transcriber: transcriber)
        let viewModel = ViewFixtures.chatViewModel(voiceInputController: controller)
        let window = ViewHost.host(Composer(viewModel: viewModel))
        viewModel.prompt = "Draft"
        ViewHost.pump()

        XCTAssertTrue(ViewHost.activate(labelContains: "Start voice input", in: window))
        waitForVoiceInputState(.listening, viewModel: viewModel)
        transcriber.emit("first")
        XCTAssertEqual(viewModel.prompt, "Draft first")

        XCTAssertTrue(ViewHost.activate(labelContains: "Stop voice input", in: window))
        transcriber.emit("late result", session: 0)
        XCTAssertEqual(viewModel.prompt, "Draft first")
    }

    func testVoiceInputFailureDisplaysError() {
        let transcriber = MockSpeechTranscriber()
        let controller = VoiceInputController(transcriber: transcriber)
        let viewModel = ViewFixtures.chatViewModel(voiceInputController: controller)
        let window = ViewHost.host(ContentView(viewModel: viewModel))

        XCTAssertTrue(ViewHost.activate(labelContains: "Start voice input", in: window))
        waitForVoiceInputState(.listening, viewModel: viewModel)
        transcriber.fail(VoiceInputError.recognizerUnavailable)
        ViewHost.pump(0.2)

        XCTAssertEqual(
            viewModel.errorMessage,
            VoiceInputError.recognizerUnavailable.localizedDescription
        )
        XCTAssertNotNil(
            ViewHost.element(
                labelContains: VoiceInputError.recognizerUnavailable.localizedDescription,
                in: window
            )
        )
        XCTAssertEqual(viewModel.voiceInputState, .idle)
    }

    func testDeniedVoiceInputPermissionPreservesDraft() {
        let transcriber = MockSpeechTranscriber()
        transcriber.authorizationError = VoiceInputError.microphoneDenied
        let controller = VoiceInputController(transcriber: transcriber)
        let viewModel = ViewFixtures.chatViewModel(voiceInputController: controller)
        let window = ViewHost.host(Composer(viewModel: viewModel))
        viewModel.prompt = "Keep this draft"
        ViewHost.pump()

        XCTAssertTrue(ViewHost.activate(labelContains: "Start voice input", in: window))
        waitForVoiceInputState(.idle, viewModel: viewModel)

        XCTAssertEqual(viewModel.prompt, "Keep this draft")
        XCTAssertEqual(transcriber.startCount, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            VoiceInputError.microphoneDenied.localizedDescription
        )
    }

    func testSendingStopsVoiceInput() {
        let transport = makeTransport()
        let transcriber = MockSpeechTranscriber()
        let controller = VoiceInputController(transcriber: transcriber)
        let viewModel = ViewFixtures.chatViewModel(
            transport: transport,
            voiceInputController: controller
        )
        let window = ViewHost.host(Composer(viewModel: viewModel))
        viewModel.prompt = "Dictated message"
        ViewHost.pump()

        XCTAssertTrue(ViewHost.activate(labelContains: "Start voice input", in: window))
        waitForVoiceInputState(.listening, viewModel: viewModel)
        XCTAssertTrue(ViewHost.activate(labelContains: "Send message", in: window))

        let deadline = Date().addingTimeInterval(3)
        while transport.sentPrompts.isEmpty && Date() < deadline {
            ViewHost.pump(0.1)
        }
        XCTAssertEqual(viewModel.voiceInputState, .idle)
        XCTAssertEqual(transcriber.stopCount, 1)
        XCTAssertEqual(transport.sentPrompts, ["Dictated message"])
    }

    func testProcessingShowsStopButtonAndStops() {
        let transport = makeTransport()
        transport.sendBehavior = .waitUntilCancelled
        let viewModel = ViewFixtures.chatViewModel(transport: transport)
        let window = ViewHost.host(Composer(viewModel: viewModel))

        viewModel.prompt = "Slow request"
        ViewHost.pump(0.2)
        viewModel.sendPrompt()

        let deadline = Date().addingTimeInterval(3)
        while !viewModel.isProcessing && Date() < deadline {
            ViewHost.pump(0.1)
        }
        XCTAssertTrue(viewModel.isProcessing)
        ViewHost.pump(0.3)

        XCTAssertTrue(ViewHost.activate(labelContains: "Stop response", in: window))
        let stopDeadline = Date().addingTimeInterval(3)
        while viewModel.isProcessing && Date() < stopDeadline {
            ViewHost.pump(0.1)
        }
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testModeMenuPresentsSheetAndSelectsMode() {
        let viewModel = ViewFixtures.chatViewModel(transport: makeTransport())
        let window = ViewHost.host(Composer(viewModel: viewModel))

        XCTAssertTrue(ViewHost.activate(labelContains: "Chat mode: Safe", in: window))
        ViewHost.pump(0.5)

        var sheetWindow: UIWindow?
        for candidate in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }) {
            if ViewHost.element(labelContains: "Accept Edits", in: candidate) != nil {
                sheetWindow = candidate
                break
            }
        }

        if let sheetWindow {
            ViewHost.activate(labelContains: "Accept Edits", in: sheetWindow)
            ViewHost.pump(0.5)
            XCTAssertEqual(viewModel.activeMode, .accept)
        }
    }

    private func waitForVoiceInputState(
        _ expectedState: VoiceInputState,
        viewModel: ChatViewModel,
        timeout: TimeInterval = 1
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.voiceInputState != expectedState && Date() < deadline {
            ViewHost.pump(0.05)
        }
        XCTAssertEqual(viewModel.voiceInputState, expectedState)
        ViewHost.pump()
    }
}

@MainActor
final class ToolCallViewTests: XCTestCase {
    func testCompletedToolExpandsToShowInputAndResult() {
        let message = ViewFixtures.toolMessage(
            name: "read_file",
            state: .completed,
            content: "file contents here"
        )
        let window = ViewHost.host(ToolCallView(message: message))

        XCTAssertNotNil(ViewHost.element(labelContains: "Tool call: Read File", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Tool call: Read File", in: window))
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(valueContains: "expanded", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Tool call: Read File", in: window))
    }

    func testFailedToolShowsErrorDetail() {
        let message = ViewFixtures.toolMessage(
            name: "run_command",
            state: .failed,
            content: "command not found",
            arguments: ["cmd": .string("nope")]
        )
        let window = ViewHost.host(ToolCallView(message: message))
        XCTAssertTrue(ViewHost.activate(labelContains: "Tool call: Run Command", in: window))
        ViewHost.pump(0.2)
    }

    func testRunningToolShowsRunningStatus() {
        let message = ViewFixtures.toolMessage(name: "grep_search", state: .running, arguments: [:])
        let window = ViewHost.host(ToolCallView(message: message))
        XCTAssertNotNil(ViewHost.element(valueContains: "Running", in: window))
    }

    func testNilToolMetadataFallsBackToDefaults() {
        let message = ViewFixtures.toolMessage(name: nil, state: nil, arguments: nil)
        let window = ViewHost.host(ToolCallView(message: message))
        XCTAssertNotNil(ViewHost.element(labelContains: "Tool call: Tool", in: window))
    }

    func testIconographyVariantsRender() {
        for name in ["edit_file", "read_file", "bash", "grep_search", "list_dir", "mystery"] {
            let message = ViewFixtures.toolMessage(name: name, state: .completed)
            _ = ViewHost.host(ToolCallView(message: message))
        }
    }
}

@MainActor
final class ToolCallGroupViewTests: XCTestCase {
    func testGroupRendersAndCollapses() {
        let messages = [
            ViewFixtures.toolMessage(id: "t1", name: "read_file", state: .completed),
            ViewFixtures.toolMessage(id: "t2", name: "edit_file", state: .completed),
            ViewFixtures.toolMessage(id: "t3", name: "bash", state: .failed, content: "boom")
        ]
        let window = ViewHost.host(ToolCallGroupView(messages: messages))

        let title = ToolCallGroupSummary.title(for: messages)
        XCTAssertNotNil(ViewHost.element(labelContains: title, in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: title, in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: title, in: window))
    }

    func testGroupWithRunningToolShowsRunningTitle() {
        let messages = [
            ViewFixtures.toolMessage(id: "t1", name: "read_file", state: .running),
            ViewFixtures.toolMessage(id: "t2", name: "bash", state: .completed)
        ]
        let window = ViewHost.host(ToolCallGroupView(messages: messages))
        XCTAssertNotNil(ViewHost.element(labelContains: "Running 2 tools", in: window))
    }
}

final class ToolCallGroupSummaryTests: XCTestCase {
    private func message(name: String?, state: ToolCallState? = .completed) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .tool, content: "", toolName: name, toolState: state)
    }

    func testEmptyMessagesFallBackToGenericTitle() {
        XCTAssertEqual(ToolCallGroupSummary.title(for: []), "Tool activity")
    }

    func testRunningMessagesReportCount() {
        let messages = [message(name: "read_file", state: .running), message(name: "bash")]
        XCTAssertEqual(ToolCallGroupSummary.title(for: messages), "Running 2 tools")
    }

    func testSingleCategorySingular() {
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "edit_file")]), "Edited a file")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "read_file")]), "Read a file")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "bash")]), "Ran a command")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "grep_search")]), "Searched")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "list_dir")]), "Listed files")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "mystery")]), "Used a tool")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: nil)]), "Used a tool")
    }

    func testPluralAndMultiCategorySentences() {
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "edit_a"), message(name: "write_b")]),
            "Edited files"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "read_a"), message(name: "read_b")]),
            "Read files"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "exec"), message(name: "shell")]),
            "Ran commands"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "read_file"), message(name: "bash")]),
            "Read a file and ran a command"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(
                for: [message(name: "read_file"), message(name: "bash"), message(name: "grep_search")]
            ),
            "Read a file, ran a command, and searched"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "tool_a"), message(name: "tool_b")]),
            "Used tools"
        )
    }
}
