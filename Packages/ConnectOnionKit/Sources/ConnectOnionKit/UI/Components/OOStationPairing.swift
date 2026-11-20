import SwiftUI

/// The word under a Claude Station's name in the sidebar, on the Claude Code tint.
public struct OOStationCaption: View {
    public init() {}

    public var body: some View {
        Text("Station")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(OOColor.claudeCodeTintText)
    }
}

/// The pairing-code field for an unpaired Claude Station: the code, a Pair button, and what the host said.
/// The app shows it in the Station's Work Room pane and calls `WorkRoomStore.pairStation(code:)` from `onPair`.
public struct OOStationPairingView: View {
    private let pairing: StationPairing
    private let onPair: (String) -> Void
    @State private var code = ""

    public init(pairing: StationPairing, onPair: @escaping (String) -> Void) {
        self.pairing = pairing
        self.onPair = onPair
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OOSpace.medium) {
            Text("Pair with your terminal")
                .font(OOFont.headline(size: 22, relativeTo: .title2))
                .foregroundStyle(OOColor.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Enter the pairing code shown by your Claude Code terminal.")
                .font(.body)
                .foregroundStyle(OOColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            OOComposerFrame {
                TextField("Pairing code", text: $code)
                    .foregroundStyle(OOColor.ink)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(OOSpace.medium)
                    .disabled(!pairing.canPair)
                    .onSubmit(submit)
                    .accessibilityLabel("Pairing code")
            }
            Button("Pair", action: submit)
                .buttonStyle(.ooPrimary)
                .disabled(!pairing.canPair || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Pair with Claude Station")
            status
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(OOSpace.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OOColor.surface)
    }

    @ViewBuilder private var status: some View {
        switch pairing.state {
        case .failed(let reason):
            note(reason, OOColor.failureText)
        case .pairing:
            Label("Pairing with your terminal", systemImage: "hourglass")
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
        case .paired:
            note("Paired. Opening the session.", OOColor.inkSecondary)
        case .unpaired:
            EmptyView()
        }
        if let reason = pairing.unavailableReason, pairing.state != .pairing {
            note(reason, OOColor.inkSecondary)
        }
    }

    private func submit() {
        if pairing.canPair {
            onPair(code)
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Station pairing") {
    OOPreviewPair {
        OOStationPairingView(pairing: StationPairing(), onPair: { _ in })
            .frame(width: 320)
    }
}
