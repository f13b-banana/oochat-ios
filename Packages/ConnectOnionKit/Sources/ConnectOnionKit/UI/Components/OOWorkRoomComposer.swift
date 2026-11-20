import SwiftUI

/// The app's microphone for the Work Room composer: its voice service's state, an optional guidance line for a failure
/// (the same wording the app's main composer shows), and the toggle that starts or stops dictation. The app appends
/// the finished transcription with `WorkRoomStore.appendDictation(_:in:)`.
public struct OOWorkRoomMic {
    public enum State: Equatable, Sendable {
        case idle, recording, transcribing
    }

    let state: State
    let guidance: String?
    let toggle: () -> Void

    public init(state: State, guidance: String? = nil, toggle: @escaping () -> Void) {
        self.state = state
        self.guidance = guidance
        self.toggle = toggle
    }
}

/// The slim composer at the bottom of a Work Room: a text field and Send on the composer frame, for
/// Provider Input only. It is always drawn; when it cannot send it is disabled and says why.
public struct OOWorkRoomComposer: View {
    private let composer: WorkRoomComposer
    private let provider: OIPProvider
    private let draft: Binding<String>
    private let onSend: () -> Void
    private let mic: OOWorkRoomMic?

    /// `draft` is bound to the store's draft (`WorkRoomStore.setDraft`); `onSend` calls `WorkRoomStore.send(in:)`.
    public init(composer: WorkRoomComposer, provider: OIPProvider, draft: Binding<String>,
                onSend: @escaping () -> Void, mic: OOWorkRoomMic? = nil) {
        self.composer = composer
        self.provider = provider
        self.draft = draft
        self.onSend = onSend
        self.mic = mic
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OOSpace.small) {
            if let rejection = composer.rejection {
                note(rejection, OOColor.failureText)
            }
            if composer.isOverLimit {
                note("Messages can be up to 12,000 characters.", OOColor.failureText)
            }
            if let guidance = mic?.guidance {
                note(guidance, OOColor.failureText)
            }
            OOComposerFrame {
                HStack(alignment: .bottom) {
                    TextField("Message \(provider.displayName)", text: draft, axis: .vertical)
                        .lineLimit(1...6)
                        .foregroundStyle(OOColor.ink)
                        .padding(.vertical, OOSpace.medium)
                        .disabled(composer.unavailableReason != nil)
                        .accessibilityLabel("Message to \(provider.displayName)")
                    if let mic {
                        micButton(mic)
                    }
                    OOSendButton(action: onSend)
                        .disabled(!composer.canSend)
                        .accessibilityLabel("Send message to \(provider.displayName)")
                }
                .padding(.leading, OOSpace.large)
            }
            if let reason = composer.unavailableReason {
                note(reason, OOColor.inkSecondary)
            }
        }
        .frame(maxWidth: 720)
        .padding(OOSpace.large)
        .frame(maxWidth: .infinity)
        .background(OOColor.surface)
    }

    private func micButton(_ mic: OOWorkRoomMic) -> some View {
        Button(action: mic.toggle) {
            Group {
                if mic.state == .transcribing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: mic.state == .recording ? "mic.fill" : "mic")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(mic.state == .recording ? OOColor.failureText : OOColor.inkSecondary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!composer.canDictate)
        .accessibilityLabel(micLabel(mic.state))
        .accessibilityValue(mic.state == .recording ? "Listening" : "")
    }

    private func micLabel(_ state: OOWorkRoomMic.State) -> String {
        switch state {
        case .idle: "Dictate a message to \(provider.displayName)"
        case .recording: "Stop dictation"
        case .transcribing: "Transcribing"
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
