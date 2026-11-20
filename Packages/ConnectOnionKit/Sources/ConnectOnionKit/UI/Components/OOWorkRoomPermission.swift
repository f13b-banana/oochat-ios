import SwiftUI

/// The Permission Profile selector in the Work Room header. It lists the Provider's own option names as the
/// host supplied them, shows options the host's Outer Mode ceiling rules out as disabled with the host's reason,
/// keeps the old profile on screen with a pending note while the host decides, and asks for a separate risk
/// confirmation before an elevated option (Bypass permissions, Full access). A refused change keeps the old
/// profile and offers Retry.
struct OOWorkRoomPermission: View {
    let permission: WorkRoomPermission
    let provider: OIPProvider
    /// The app's call to `WorkRoomStore.changePermission(to:confirmRisk:in:)`.
    let onChange: (String, Bool) -> Void
    @State private var confirming: WorkRoomPermission.Option?

    var body: some View {
        VStack(alignment: .leading, spacing: OOSpace.small) {
            Menu {
                ForEach(permission.options) { option in
                    Button {
                        choose(option)
                    } label: {
                        if option.id == permission.activeID {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(title(of: option))
                        }
                    }
                    .disabled(!permission.offers(option))
                    .accessibilityLabel(title(of: option))
                    .accessibilityHint(option.description)
                }
            } label: {
                Label(menuTitle, systemImage: permission.isPending ? "hourglass" : "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OOColor.ink)
            }
            .disabled(permission.unavailableReason != nil)
            .accessibilityLabel("Permission Profile")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Chooses how \(provider.displayName) behaves on its next turn")
            if let reason = permission.unavailableReason {
                note(reason, OOColor.inkSecondary)
            }
            if let failure = permission.failure {
                note(failure.text, OOColor.failureText)
                if let option = permission.options.first(where: { $0.id == failure.optionID }), permission.offers(option) {
                    Button("Retry") { choose(option) }
                        .buttonStyle(.ooSecondary)
                        .accessibilityLabel("Retry changing to \(option.label)")
                }
            }
        }
        .confirmationDialog(
            "Use \(confirming?.label ?? "this profile")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { option in
            Button("Use \(option.label)", role: .destructive) { onChange(option.id, true) }
            Button("Cancel", role: .cancel) {}
        } message: { option in
            Text("\(option.label) lets \(provider.displayName) act with fewer safeguards. \(option.description)")
        }
    }

    private var menuTitle: String {
        if let pending = permission.pendingLabel {
            return "\(permission.activeLabel), changing to \(pending)"
        }
        return permission.activeLabel
    }

    private var accessibilityValue: String {
        permission.pendingLabel.map { "\(permission.activeLabel), changing to \($0), waiting for the host" }
            ?? permission.activeLabel
    }

    private func title(of option: WorkRoomPermission.Option) -> String {
        option.disabledReason.map { "\(option.label), unavailable: \($0)" } ?? option.label
    }

    /// An elevated option waits for the separate confirmation; any other goes straight to the app.
    private func choose(_ option: WorkRoomPermission.Option) {
        if option.isElevated {
            confirming = option
        } else {
            onChange(option.id, false)
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
