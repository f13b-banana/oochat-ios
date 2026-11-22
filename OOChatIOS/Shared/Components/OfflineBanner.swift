import ConnectOnionKit
import SwiftUI

// Neutral colours, because being offline is a normal state.
struct OfflineBanner: View {
    var isRetrying = false
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: OOSpace.tiny) {
            Label {
                Text("You're offline. Messages will be queued.")
                    .foregroundStyle(OOColor.ink)
            } icon: {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(OOColor.inkSecondary)
            }
            .font(.footnote.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, OOSpace.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRetry) {
                Text(isRetrying ? "Retrying…" : "Retry")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(OOColor.ink)
                    .frame(minWidth: ooMinimumTarget, minHeight: ooMinimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AppPressButtonStyle())
            .disabled(isRetrying)
            .accessibilityLabel(isRetrying ? "Retrying connection" : "Retry connection")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OOColor.inkSecondary)
                    .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AppPressButtonStyle())
            .accessibilityLabel("Dismiss offline banner")
        }
        .padding(.leading, OOSpace.large)
        .padding(.trailing, OOSpace.tiny)
        .background(OOColor.hover.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            OOColor.hairline.frame(height: 1)
        }
        .accessibilityIdentifier("offlineBanner")
    }
}
