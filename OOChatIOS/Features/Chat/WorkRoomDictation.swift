import Combine
import ConnectOnionKit
import Foundation

/// Dictation for one Work Room composer, driven by the chat's voice controller. A finished
/// transcription is appended to the Work Room draft and never sent; a failure leaves the draft
/// alone and shows the same guidance text as the main composer.
@MainActor
final class WorkRoomDictation: ObservableObject {
    @Published private(set) var guidance: String?

    private let controller: VoiceInputController
    private var stateCancellable: AnyCancellable?
    private var isOwner = false
    private var latestTranscript = ""
    private var append: ((String) -> Void)?

    init(controller: VoiceInputController) {
        self.controller = controller
        stateCancellable = controller.$state
            .filter { $0 == .idle }
            .sink { [weak self] _ in
                // Deferred so a failure report, which arrives just after the state change, wins.
                Task { @MainActor in self?.finish() }
            }
    }

    var micState: OOWorkRoomMic.State {
        isOwner && controller.isActive ? .recording : .idle
    }

    func toggle(in roomID: String, append: @escaping (String) -> Void) {
        if isOwner {
            controller.stop()
            return
        }
        guard !controller.isActive else {
            return
        }
        guidance = nil
        latestTranscript = ""
        self.append = append
        isOwner = true
        controller.start(
            promptPrefix: "",
            conversationID: roomID,
            transcriptHandler: { [weak self] _, text in
                self?.latestTranscript = text
            },
            failureHandler: { [weak self] _, message in
                self?.latestTranscript = ""
                self?.guidance = message
            }
        )
    }

    /// Stops recording and drops what was heard, for when the Work Room can no longer take input.
    func cancel() {
        guidance = nil
        guard isOwner else {
            return
        }
        latestTranscript = ""
        controller.stop()
        finish()
    }

    private func finish() {
        guard isOwner, !controller.isActive else {
            return
        }
        isOwner = false
        let text = latestTranscript
        latestTranscript = ""
        if !text.isEmpty {
            append?(text)
        }
        append = nil
    }
}
