import ConnectOnionKit
import SwiftUI

struct OfflineBanner: View {
    var isRetrying = false
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        BannerRow(
            style: .neutral,
            text: "You're offline. Messages will be queued.",
            systemImage: "wifi.slash",
            retry: BannerRow.Retry(
                title: isRetrying ? "Retrying…" : "Retry",
                isDisabled: isRetrying,
                accessibilityLabel: isRetrying ? "Retrying connection" : "Retry connection",
                action: onRetry
            ),
            dismissLabel: "Dismiss offline banner",
            onDismiss: onDismiss
        )
        .accessibilityIdentifier("offlineBanner")
    }
}
