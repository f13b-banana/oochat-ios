import SwiftUI
import ConnectOnionKit

// One flat card for everything the agent asks of the person: approvals, plan review,
// questions and the Full access checkpoint. A hairline border and the card radius, no
// glass and no tinted fill, so a card reads as part of the transcript and not as an
// overlay. Colours, radius and tap target all come from the N2.2 tokens
// (`OOColor`, `OORadius`, `ooMinimumTarget`) so N2.1 can replace the values later
// without touching these views.

private struct ConversationCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(OOSpace.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                OOColor.surface,
                in: RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
                    .stroke(OOColor.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func conversationCard() -> some View {
        modifier(ConversationCardSurface())
    }
}

// The one primary choice on a card. There is never more than one of these per card.

struct CardPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            // `paper` is white in light mode and near-black in dark mode, which is the
            // readable colour on `primary` in both (primary is light mint in dark mode).
            .foregroundStyle(OOColor.paper)
            .frame(maxWidth: .infinity, minHeight: ooMinimumTarget)
            .background(
                OOColor.primary,
                in: RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.38)
            .animation(AppMotion.press, value: configuration.isPressed)
    }
}

// Every other choice: a filled neutral button, like the macOS .ooSecondary, so it reads
// on the amber decision notice and never competes with the primary one.
struct CardSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var alignment: Alignment = .center
    var tint: Color = OOColor.ink
    // Red for a destructive choice (Stop response), so it reads as a button without a red fill.
    var stroke: Color = OOColor.hairline

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, OOSpace.medium)
            .frame(maxWidth: .infinity, minHeight: ooMinimumTarget, alignment: alignment)
            .background(
                configuration.isPressed ? OOColor.surface : OOColor.paper,
                in: RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.38)
            .animation(AppMotion.press, value: configuration.isPressed)
    }
}

// Text-only action for the quiet end of a card (cancel, stop).
struct CardQuietButtonStyle: ButtonStyle {
    var tint: Color = OOColor.inkSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: ooMinimumTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(AppMotion.press, value: configuration.isPressed)
    }
}

// A small label above a line of text, used for "Scope" and "If you allow".
struct CardFieldLabel: View {
    let label: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OOColor.inkSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(OOColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
