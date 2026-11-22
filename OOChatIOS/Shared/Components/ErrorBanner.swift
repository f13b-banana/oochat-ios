import ConnectOnionKit
import SwiftUI

/// The offline and error banners under the chat's nav bar, inside the chat column.
struct ChatBanners: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.shouldShowOfflineBanner {
                OfflineBanner(isRetrying: viewModel.isRetryingConnectivity) {
                    viewModel.retryConnectivity()
                } onDismiss: {
                    viewModel.dismissOfflineBanner()
                }
                .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
            }
            ErrorBanner(
                message: viewModel.errorMessage,
                onRetry: viewModel.canRetryError ? { Task { await viewModel.reconnect() } } : nil,
                onDismiss: { viewModel.dismissError() }
            )
        }
        .animation(AppMotion.contentArrival(reduceMotion: reduceMotion), value: viewModel.shouldShowOfflineBanner)
        .animation(AppMotion.contentArrival(reduceMotion: reduceMotion), value: viewModel.errorMessage)
    }
}

// A failure, in the kit failure colours. Retry shows when trying again can help.
struct ErrorBanner: View {
    let message: String?
    var onRetry: (() -> Void)?
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let message {
            BannerRow(
                style: .failure,
                text: message,
                systemImage: "exclamationmark.triangle.fill",
                retry: onRetry.map { BannerRow.Retry(title: "Retry", action: $0) },
                dismissLabel: "Close error",
                onDismiss: onDismiss
            )
            .accessibilityIdentifier("errorBanner")
            .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
        }
    }
}

/// One line of a banner: an icon and its text, then Retry when it can help, then close.
struct BannerRow: View {
    struct Style {
        let fill: Color
        let line: Color
        let text: Color
        let icon: Color
        let dismiss: Color

        static let failure = Style(
            fill: OOColor.failureFill,
            line: OOColor.failureLine,
            text: OOColor.failureText,
            icon: OOColor.failureMark,
            dismiss: OOColor.failureText
        )
        // Neutral colours, because being offline is a normal state.
        static let neutral = Style(
            fill: OOColor.hover,
            line: OOColor.hairline,
            text: OOColor.ink,
            icon: OOColor.inkSecondary,
            dismiss: OOColor.inkSecondary
        )
    }

    struct Retry {
        let title: String
        var isDisabled = false
        var accessibilityLabel = "Retry connection"
        let action: () -> Void
    }

    let style: Style
    let text: String
    let systemImage: String
    let retry: Retry?
    let dismissLabel: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: OOSpace.tiny) {
            Label {
                Text(text)
                    .foregroundStyle(style.text)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(style.icon)
            }
            .font(.footnote.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, OOSpace.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retry {
                Button(action: retry.action) {
                    Text(retry.title)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(style.text)
                        .frame(minWidth: ooMinimumTarget, minHeight: ooMinimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AppPressButtonStyle())
                .disabled(retry.isDisabled)
                .accessibilityLabel(retry.accessibilityLabel)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.dismiss)
                    .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AppPressButtonStyle())
            .accessibilityLabel(dismissLabel)
        }
        .padding(.leading, OOSpace.large)
        .padding(.trailing, OOSpace.tiny)
        .background(style.fill)
        .overlay(alignment: .bottom) {
            style.line.frame(height: 1)
        }
    }
}
