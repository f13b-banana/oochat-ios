import SwiftUI

extension Composer {
    @ViewBuilder
    var modeMenu: some View {
        Button {
            showModeMenu = true
        } label: {
            let displayedMode = viewModel.activePendingMode ?? viewModel.activeMode
            HStack(spacing: 5) {
                Image(systemName: displayedMode.icon)
                    .foregroundStyle(AppTheme.primary)

                Text(displayedMode.label)
                    .foregroundStyle(.secondary)

                if viewModel.activePendingMode != nil {
                    Text("Pending")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }

                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, ComposerMetrics.modeHorizontalPadding)
            .padding(.vertical, ComposerMetrics.modeVerticalPadding)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(.separator).opacity(ComposerMetrics.modeStrokeOpacity), lineWidth: 0.5)
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

        if viewModel.activePendingMode == nil,
           viewModel.activeMode == .ulw,
           let turnsLeft = viewModel.activeFullAccessTurnsLeft {
            Text("\(turnsLeft) \(turnsLeft == 1 ? "turn" : "turns") left")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
    }

    var modeSheet: some View {
        VStack(spacing: 0) {
            Text("Response Mode")
                .font(.headline)
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
                .foregroundStyle(AppTheme.primary)
                .frame(width: 40, height: 40)
                .background(
                    AppTheme.primary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(mode.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if (viewModel.activePendingMode ?? viewModel.activeMode) == mode {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
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
