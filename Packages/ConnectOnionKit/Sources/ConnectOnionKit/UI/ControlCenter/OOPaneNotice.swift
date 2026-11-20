import SwiftUI

/// A short refusal over the top of the Control Center pane, with a way to put it away.
struct OOPaneNotice: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: OOSpace.small) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(OOColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(.footnote.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
                .frame(minHeight: ooMinimumTarget)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, OOSpace.medium)
        .background(OOColor.surface, in: RoundedRectangle(cornerRadius: OORadius.large))
        .overlay(RoundedRectangle(cornerRadius: OORadius.large).stroke(OOColor.hairline, lineWidth: 1))
        .padding(OOSpace.small)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Pane notice") {
    OOPaneNotice(message: "The agent has no skill called test.") {}
}
