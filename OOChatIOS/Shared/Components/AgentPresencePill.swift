import SwiftUI

// SessionStatus label
struct AgentPresencePill: View {
    let label: String
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            sizingContent
                .hidden()

            statusContent
                .id(label)
                .transition(.opacity)
        }
        .font(.caption)
        .animation(statusTransition, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session status: \(label)")
    }

    private var statusContent: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(label)
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
    }

    private var sizingContent: some View {
        HStack(spacing: 5) {
            Circle()
                .frame(width: 6, height: 6)

            // The longest label
            Text("Not Connected")
                .lineLimit(1)
        }
    }

    private var statusTransition: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : AppMotion.press
    }

    private var statusColor: Color {
        isLive ? .green : .secondary
    }
}
