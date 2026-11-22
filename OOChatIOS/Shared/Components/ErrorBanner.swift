import ConnectOnionKit
import SwiftUI

// A failure, in the kit failure colours. Retry shows when trying again can help.
struct ErrorBanner: View {
    let message: String?
    var onRetry: (() -> Void)?
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let message {
            HStack(spacing: OOSpace.tiny) {
                Label {
                    Text(message)
                        .foregroundStyle(OOColor.failureText)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(OOColor.failureMark)
                }
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, OOSpace.small)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let onRetry {
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(OOColor.failureText)
                            .frame(minWidth: ooMinimumTarget, minHeight: ooMinimumTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(AppPressButtonStyle())
                    .accessibilityLabel("Retry connection")
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(OOColor.failureText)
                        .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AppPressButtonStyle())
                .accessibilityLabel("Close error")
            }
            .padding(.leading, OOSpace.large)
            .padding(.trailing, OOSpace.tiny)
            .background(OOColor.failureFill.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) {
                OOColor.failureLine.frame(height: 1)
            }
            .accessibilityIdentifier("errorBanner")
            .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
        }
    }
}
