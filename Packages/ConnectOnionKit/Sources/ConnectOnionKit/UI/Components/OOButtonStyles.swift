import SwiftUI

/// the one green action on a screen, or red when the button's role is destructive
/// from oo-chat app/page.tsx line 94 and components/confirm-dialog.tsx
public struct OOPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let fill = configuration.role == .destructive ? OOColor.failureMark : OOColor.primary
        // white on red in both modes: O Chat's dark paper on red is 3.8:1, white is 4.8:1
        let ink = configuration.role == .destructive ? Color.white : OOColor.onPrimary
        // O Chat's green action is rounded-xl, its red one matches Cancel at rounded-lg
        let radius = configuration.role == .destructive ? OORadius.medium : OORadius.large
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? ink : OOColor.inkTertiary)
            .padding(.horizontal, OOSpace.large)
            .frame(minHeight: ooMinimumTarget)
            .background(isEnabled ? fill : OOColor.hover, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// a quiet action next to the primary one, such as Cancel
public struct OOSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.medium, style: .continuous)
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isEnabled ? OOColor.ink : OOColor.inkTertiary)
            .padding(.horizontal, OOSpace.large)
            .frame(minHeight: ooMinimumTarget)
            .background(configuration.isPressed ? OOColor.surface : OOColor.paper, in: shape)
            .overlay(shape.stroke(OOColor.hairline, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == OOPrimaryButtonStyle {
    static var ooPrimary: OOPrimaryButtonStyle { OOPrimaryButtonStyle() }
}

public extension ButtonStyle where Self == OOSecondaryButtonStyle {
    static var ooSecondary: OOSecondaryButtonStyle { OOSecondaryButtonStyle() }
}

public extension View {
    /// confirm before a destructive action, with Cancel as the default
    /// a native alert, so it gets focus, Escape and VoiceOver for free
    func ooConfirm(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        confirmLabel: String = "Delete",
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(confirmLabel, role: .destructive, action: onConfirm)
        } message: {
            if let message { Text(message) }
        }
    }
}

#Preview("Buttons") {
    OOPreviewPair {
        VStack(spacing: 12) {
            Button {} label: { Text("Connect").frame(maxWidth: .infinity) }
                .buttonStyle(.ooPrimary)
            Button("Connect") {}
                .buttonStyle(.ooPrimary)
                .disabled(true)
            HStack {
                Button("Cancel") {}
                    .buttonStyle(.ooSecondary)
                Button("Remove agent", role: .destructive) {}
                    .buttonStyle(.ooPrimary)
            }
        }
        .frame(width: 260)
    }
}
