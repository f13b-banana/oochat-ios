import XCTest
@testable import OOChatIOS

@MainActor
final class WorkRoomDictationTests: XCTestCase {
    private var transcriber: MockSpeechTranscriber!
    private var dictation: WorkRoomDictation!
    private var appended: [String] = []

    override func setUp() {
        super.setUp()
        transcriber = MockSpeechTranscriber()
        dictation = WorkRoomDictation(controller: VoiceInputController(transcriber: transcriber))
        appended = []
    }

    func testFinishedTranscriptionIsAppendedOnce() async {
        await startRecording()
        transcriber.emit("run the", isFinal: false)
        transcriber.emit("run the tests", isFinal: true)
        await settle()

        XCTAssertEqual(appended, ["run the tests"])
        XCTAssertEqual(dictation.micState, .idle)
        XCTAssertNil(dictation.guidance)
    }

    func testFailureKeepsDraftAndShowsMainComposerGuidance() async {
        transcriber.authorizationError = VoiceInputError.microphoneDenied
        dictation.toggle(in: "room") { self.appended.append($0) }
        await settle()

        XCTAssertTrue(appended.isEmpty)
        XCTAssertEqual(dictation.guidance, VoiceInputError.microphoneDenied.localizedDescription)
        XCTAssertEqual(dictation.micState, .idle)
    }

    func testFailureAfterPartialResultAppendsNothing() async {
        await startRecording()
        transcriber.emit("half a sentence", isFinal: false)
        transcriber.fail(VoiceInputError.recognizerUnavailable)
        await settle()

        XCTAssertTrue(appended.isEmpty)
        XCTAssertEqual(dictation.guidance, VoiceInputError.recognizerUnavailable.localizedDescription)
    }

    func testCancelDropsWhatWasHeard() async {
        await startRecording()
        transcriber.emit("never mind", isFinal: false)
        dictation.cancel()
        await settle()

        XCTAssertTrue(appended.isEmpty)
        XCTAssertEqual(dictation.micState, .idle)
        XCTAssertEqual(transcriber.stopCount, 1)
    }

    func testCancelClearsGuidanceFromEarlierFailure() async {
        transcriber.authorizationError = VoiceInputError.microphoneDenied
        dictation.toggle(in: "room") { self.appended.append($0) }
        await settle()
        XCTAssertNotNil(dictation.guidance)

        dictation.cancel()

        XCTAssertNil(dictation.guidance)
    }

    func testTogglingOffKeepsWhatWasHeard() async {
        await startRecording()
        transcriber.emit("ship it", isFinal: false)
        dictation.toggle(in: "room") { self.appended.append($0) }
        await settle()

        XCTAssertEqual(appended, ["ship it"])
    }

    private func startRecording() async {
        dictation.toggle(in: "room") { self.appended.append($0) }
        for _ in 0..<50 where transcriber.startCount == 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(dictation.micState, .recording)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
