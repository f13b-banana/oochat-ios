import SwiftUI

/// control and chat tabs
public enum OOAgentView: Hashable, Sendable {
    case control
    case chat
}

public struct OOViewSwitch: View {
    @Binding private var selection: OOAgentView
    private let attention: OOAgentView?

    public init(selection: Binding<OOAgentView>, attention: OOAgentView? = nil) {
        _selection = selection
        self.attention = attention
    }

    public var body: some View {
        HStack(spacing: OOSpace.tiny) {
            tab(.control, title: "Control", spoken: "Control Center")
            tab(.chat, title: "Chat", spoken: "Chat")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent view")
    }

    private func tab(_ view: OOAgentView, title: String, spoken: String) -> some View {
        let isSelected = selection == view
        let isWaiting = Self.isWaiting(view, selection: selection, attention: attention)
        return Button {
            selection = view
        } label: {
            HStack(spacing: OOSpace.tiny) {
                Text(title)
                    .font(.footnote.weight(.medium))
                if isWaiting {
                    OOWaitingDot()
                }
            }
            .foregroundStyle(isSelected ? OOColor.ink : OOColor.inkSecondary)
            .padding(.horizontal, OOSpace.small)
            .frame(minHeight: ooMinimumTarget)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? OOColor.selectedRule : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.spokenLabel(spoken, isWaiting: isWaiting))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    static func isWaiting(_ view: OOAgentView, selection: OOAgentView, attention: OOAgentView?) -> Bool {
        attention == view && selection != view
    }

    static func spokenLabel(_ spoken: String, isWaiting: Bool) -> String {
        isWaiting ? "\(spoken), waiting for you" : spoken
    }
}

/// pulse and colour
struct OOWaitingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false
    var color = OOColor.inkTertiary

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview("View switch") {
    struct Demo: View {
        @State var selection = OOAgentView.control
        var body: some View {
            OOViewSwitch(selection: $selection, attention: .chat)
                .padding()
                .background(OOColor.paper)
                .preferredColorScheme(.dark)
        }
    }
    return Demo()
}
