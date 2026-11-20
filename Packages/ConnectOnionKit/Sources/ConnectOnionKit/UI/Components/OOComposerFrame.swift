import SwiftUI

/// the composer card: paper, hairline, radius 10 and a soft shadow
/// the app puts its own text field, buttons and mode bar inside
/// from oo-chat components/chat/chat-input.tsx near line 196
public struct OOComposerFrame<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
        content
            .background(OOColor.paper, in: shape)
            .overlay(shape.stroke(OOColor.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

/// 36 point green square in a 44 point target, the one green control in a conversation
/// from oo-chat components/chat/chat-input.tsx near line 365
public struct OOSendButton: View {
    @Environment(\.isEnabled) private var isEnabled
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isEnabled ? OOColor.onPrimary : OOColor.inkTertiary)
                .frame(width: 36, height: 36)
                .background(
                    isEnabled ? OOColor.primary : OOColor.hover,
                    in: RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                )
                .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send message")
    }
}

/// 36 point dark square holding a small paper square, shown while the agent runs
/// from oo-chat components/chat/chat-input.tsx near line 353
public struct OOStopButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(OOColor.paper)
                .frame(width: 12, height: 12)
                .frame(width: 36, height: 36)
                .background(OOColor.ink, in: RoundedRectangle(cornerRadius: OORadius.large, style: .continuous))
                .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop agent")
    }
}

#Preview("Composer frame") {
    OOPreviewPair {
        VStack(spacing: 12) {
            OOComposerFrame {
                HStack {
                    Text("Ask anything").foregroundStyle(OOColor.inkTertiary)
                    Spacer()
                    OOSendButton {}
                }
                .padding(.leading, OOSpace.large)
            }
            OOComposerFrame {
                HStack {
                    Text("Working…").foregroundStyle(OOColor.inkSecondary)
                    Spacer()
                    OOStopButton {}
                }
                .padding(.leading, OOSpace.large)
            }
        }
        .frame(width: 300)
    }
}
