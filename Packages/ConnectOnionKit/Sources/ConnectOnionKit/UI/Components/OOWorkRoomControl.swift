import SwiftUI

/// Who has Control of a Claude Station, in the Work Room header, with the two ways to change it.
/// Control moves only when the host confirms, so a change waiting for the host shows progress and nothing else moves.
struct OOWorkRoomControl: View {
    let control: WorkRoomControl
    /// The app's call to `WorkRoomStore.changeControl(_:in:)`.
    let onChange: (OIPProviderControlAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OOSpace.small) {
            Text("Control: \(control.ownerLabel)" + (control.phaseLabel.map { ". \($0)" } ?? ""))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OOColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits {
                HStack(spacing: OOSpace.small) { buttons }
                VStack(alignment: .leading, spacing: OOSpace.small) { buttons }
            }
            if let pending = control.pending {
                ProgressView(pending == .take ? "Taking control" : "Returning control")
                    .font(.subheadline)
            }
            if let failure = control.failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(OOColor.failureText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = control.unavailableReason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        Button("Take control here") { onChange(.take) }
            .buttonStyle(.ooSecondary)
            .disabled(!control.canTake)
            .accessibilityHint(control.canTake ? "Sends your messages to Claude Code from this device" : unavailableHint)
        Button("Return to terminal") { onChange(.release) }
            .buttonStyle(.ooSecondary)
            .disabled(!control.canRelease)
            .accessibilityHint(control.canRelease ? "Gives control back to the terminal" : unavailableHint)
    }

    private var unavailableHint: String {
        control.unavailableReason ?? "Not available right now. \(control.ownerLabel) has control."
    }
}
