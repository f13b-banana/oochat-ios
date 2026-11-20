import SwiftUI
import ConnectOnionKit

// The words next to the mode capsule while Ultra Work counts turns.
enum ComposerTurnsLeft {
    static func label(_ turnsLeft: Int) -> String {
        "\(turnsLeft) \(turnsLeft == 1 ? "turn" : "turns") left"
    }
}

extension Composer {
    // The execution mode and, beside it, how many turns Ultra Work has left (16.2).
    var modeMenu: some View {
        HStack(spacing: OOSpace.small) {
            modeButton
            if viewModel.activePendingMode == nil,
               viewModel.activeMode == .ulw,
               let turnsLeft = viewModel.activeFullAccessTurnsLeft {
                Text(ComposerTurnsLeft.label(turnsLeft))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(OOColor.inkSecondary)
                    .lineLimit(1)
                    .accessibilityLabel(ComposerTurnsLeft.label(turnsLeft))
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var modeButton: some View {
        Button {
            showModeMenu = true
        } label: {
            let displayedMode = viewModel.activePendingMode ?? viewModel.activeMode
            HStack(spacing: 5) {
                Image(systemName: displayedMode.icon)
                    .foregroundStyle(OOColor.primary)

                Text(displayedMode.label)
                    .foregroundStyle(OOColor.ink)

                if viewModel.activePendingMode != nil {
                    Text("Pending")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OOColor.inkSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(OOColor.currentTint, in: Capsule())
                }

                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(OOColor.inkSecondary)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, ComposerMetrics.modeHorizontalPadding)
            .padding(.vertical, ComposerMetrics.modeVerticalPadding)
            .background(OOColor.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(OOColor.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.96, pressedOpacity: 0.88))
        .disabled(viewModel.activeConversation == nil || viewModel.isProcessing || viewModel.activePendingMode != nil)
        .accessibilityLabel(viewModel.activePendingMode.map { "Chat mode: \($0.label), pending" }
                            ?? "Chat mode: \(viewModel.activeMode.label)")
        .popover(isPresented: $showModeMenu) {
            modeSheet
                .frame(idealWidth: ComposerMetrics.modePopoverWidth)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.height(sheetHeight)])
                .presentationDragIndicator(.visible)
        }
    }

    var modeSheet: some View {
        VStack(spacing: 0) {
            Text("Response Mode")
                .font(.headline)
                .foregroundStyle(OOColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(viewModel.offeredModes) { mode in
                Button {
                    viewModel.setMode(mode)
                    showModeMenu = false
                } label: {
                    modeRow(for: mode)
                }
                .buttonStyle(AppPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.86))
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { sheetHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newValue in
                        sheetHeight = newValue
                    }
            }
        }
    }

    func modeRow(for mode: ChatMode) -> some View {
        HStack(spacing: 14) {
            Image(systemName: mode.icon)
                .font(.system(size: 18))
                .foregroundStyle(OOColor.primary)
                .frame(width: 40, height: 40)
                .background(
                    OOColor.currentTint,
                    in: RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OOColor.ink)
                Text(mode.detail)
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if (viewModel.activePendingMode ?? viewModel.activeMode) == mode {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OOColor.primary)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.92).combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// Presentation details for each mode, kept out of the model layer.
private extension ChatMode {
    var icon: String {
        switch self {
        case .safe:
            return "shield"
        case .plan:
            return "list.bullet.clipboard"
        case .accept:
            return "checkmark.circle"
        case .ulw:
            return "bolt.fill"
        }
    }
    var detail: String {
        switch self {
        case .plan:
            return "Ask before any change."
        case .safe, .accept:
            return "Review each action and approve safe work automatically."
        case .ulw:
            return "Bypass approval for the bounded user-driven turns shown."
        }
    }
}
