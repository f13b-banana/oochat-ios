import ConnectOnionKit
import SwiftUI
// Sidebar button styles.
struct SidebarPressedRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if configuration.isPressed || isHighlighted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(OOColor.hover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(AppMotion.press, value: configuration.isPressed || isHighlighted)
    }
}

struct SidebarFooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35)
            .animation(AppMotion.press, value: configuration.isPressed)
            .animation(AppMotion.press, value: isEnabled)
    }
}

struct SidebarConversationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? OOColor.ink : OOColor.inkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                // One selected item, in the current-item tint; a press is only hairline grey.
                if isSelected || configuration.isPressed {
                    RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                        .fill(isSelected ? OOColor.currentTint : OOColor.hairline)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: OORadius.large, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(AppMotion.press, value: configuration.isPressed)
            .animation(AppMotion.press, value: isSelected)
    }
}
