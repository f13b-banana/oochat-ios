import SwiftUI
import ConnectOnionKit

extension Composer {
    var inputBar: some View {
        HStack(alignment: .center, spacing: ComposerMetrics.inputSpacing) {
            attachmentMenu

            // What you type is ink; only the placeholder is the secondary grey.
            TextField(
                "Message the agent",
                text: $viewModel.prompt,
                prompt: Text("Message the agent").foregroundStyle(OOColor.inkSecondary),
                axis: .vertical
            )
                .font(.body)
                .foregroundStyle(OOColor.ink)
                .lineLimit(1...4)
                .focused($isPromptFocused)
                .tint(AppTheme.primary)
                .frame(minHeight: ComposerMetrics.sendButtonSize, alignment: .center)
                .padding(.vertical, ComposerMetrics.inputVerticalPadding)
                .allowsHitTesting(!viewModel.isVoiceInputActive)

            voiceInputButton
            sendButton
        }
        .padding(.leading, ComposerMetrics.horizontalPadding)
        .padding(.trailing, ComposerMetrics.trailingPadding)
        .padding(.vertical, ComposerMetrics.verticalPadding)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous)
                .stroke(
                    isPromptFocused
                        ? AppTheme.primary.opacity(ComposerMetrics.focusedInputStrokeOpacity)
                        : Color(.separator).opacity(ComposerMetrics.inputStrokeOpacity),
                    lineWidth: isPromptFocused ? 1 : 0.5
                )
        )
        .shadow(
            color: AppTheme.primary.opacity(isPromptFocused ? ComposerMetrics.focusedInputShadowOpacity : 0),
            radius: ComposerMetrics.focusedInputShadowRadius,
            y: ComposerMetrics.focusedInputShadowYOffset
        )
        .animation(AppMotion.press, value: isPromptFocused)
    }

    var voiceInputButton: some View {
        Button {
            let wasActive = viewModel.isVoiceInputActive
            viewModel.toggleVoiceInput()
            isPromptFocused = wasActive
        } label: {
            Group {
                if viewModel.voiceInputState == .requestingPermission {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(
                        systemName: viewModel.voiceInputState == .listening
                            ? "mic.fill"
                            : "mic"
                    )
                    .font(.body.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive: viewModel.voiceInputState == .listening && !reduceMotion
                    )
                }
            }
            .foregroundStyle(
                viewModel.voiceInputState == .listening
                    ? Color.red
                    : AppTheme.primary
            )
            .frame(
                width: ComposerMetrics.voiceInputButtonSize,
                height: ComposerMetrics.sendButtonSize
            )
            .background {
                if viewModel.voiceInputState == .listening {
                    Circle()
                        .fill(
                            Color.red.opacity(
                                ComposerMetrics.voiceInputActiveBackgroundOpacity
                            )
                        )
                }
            }
            .frame(width: ooMinimumTarget, height: ooMinimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.92, pressedOpacity: 0.85))
        .disabled(viewModel.activeConversation == nil || viewModel.isProcessing)
        .accessibilityLabel(voiceInputAccessibilityLabel)
        .accessibilityValue(
            viewModel.voiceInputState == .listening ? "Listening" : ""
        )
    }

    var voiceInputAccessibilityLabel: String {
        switch viewModel.voiceInputState {
        case .idle:
            return "Start voice input"
        case .requestingPermission:
            return "Cancel voice input"
        case .listening:
            return "Stop voice input"
        }
    }

    var sendButton: some View {
        Button {
            if viewModel.isProcessing {
                viewModel.stopActiveResponse()
            } else {
                viewModel.sendPrompt()
                isPromptFocused = false
            }
        } label: {
            Image(systemName: viewModel.isProcessing ? "stop.fill" : "arrow.up")
                .font(viewModel.isProcessing ? .caption.weight(.bold) : .body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: ComposerMetrics.sendButtonSize, height: ComposerMetrics.sendButtonSize)
                .glassBackground(
                    in: Circle(),
                    interactive: true,
                    tint: AppTheme.primary
                )
                .contentTransition(.symbolEffect(.replace))
                .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.92, pressedOpacity: 0.90))
        .disabled(
            !viewModel.isProcessing
                && viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && viewModel.pendingImages.isEmpty
                && viewModel.pendingFiles.isEmpty
        )
        .accessibilityLabel(viewModel.isProcessing ? "Stop response" : "Send message")
    }
}
