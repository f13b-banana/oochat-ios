import SwiftUI

/// six point dot with an optional label: green when live, red when it failed, grey otherwise
public struct OOStatusDot: View {
    public enum Tone: Sendable {
        case live, neutral, failure
    }

    private let label: String?
    private let tone: Tone

    public init(label: String? = nil, isLive: Bool) {
        self.label = label
        self.tone = isLive ? .live : .neutral
    }

    /// A failure is red so it reads differently from a wait; the label still says what happened.
    public init(label: String? = nil, tone: Tone) {
        self.label = label
        self.tone = tone
    }

    private var isLive: Bool {
        tone == .live
    }

    private var fill: Color {
        switch tone {
        case .live:
            return OOColor.live
        case .failure:
            return OOColor.failureMark
        case .neutral:
            // O Chat's neutral-400 is 2.48:1, and a status mark needs 3:1
            return OOColor.inkSecondary
        }
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(fill)
                .frame(width: 6, height: 6)
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(OOColor.inkSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? (isLive ? "Online" : "Offline"))
    }
}

/// the one status mark a tool row draws, in a fixed 16 point box
/// from oo-chat components/chat/messages/tools/tool-status.tsx
public struct OOToolStatus: View {
    public enum State: Sendable {
        case running, done, failed, stopped, idle
    }

    private let state: State
    private let isAwaitingApproval: Bool

    public init(_ state: State, isAwaitingApproval: Bool = false) {
        self.state = state
        self.isAwaitingApproval = isAwaitingApproval
    }

    public var body: some View {
        mark
            .frame(width: 16, height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spokenLabel(state, isAwaitingApproval: isAwaitingApproval))
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .done:
            circled("checkmark")
        case .stopped:
            circled("xmark")
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OOColor.failureMark)
        case .running:
            // O Chat's neutral-400 is 2.48:1, and a status mark needs 3:1
            OOWaitingDot(color: isAwaitingApproval ? OOColor.inkSecondary : OOColor.live)
        case .idle:
            Circle().fill(OOColor.hairline).frame(width: 6, height: 6)
        }
    }

    private func circled(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(OOColor.inkSecondary)
            .frame(width: 14, height: 14)
            .background(OOColor.hover, in: Circle())
    }

    static func spokenLabel(_ state: State, isAwaitingApproval: Bool) -> String {
        switch state {
        case .running: isAwaitingApproval ? "Waiting for approval" : "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .idle: "Not started"
        }
    }
}

#Preview("Status dot") {
    OOPreviewPair {
        VStack(alignment: .leading, spacing: 12) {
            OOStatusDot(label: "Running", isLive: true)
            OOStatusDot(label: "Reconnecting", isLive: false)
            OOStatusDot(label: "Can't connect", tone: .failure)
            HStack {
                OOToolStatus(.running)
                OOToolStatus(.running, isAwaitingApproval: true)
                OOToolStatus(.done)
                OOToolStatus(.failed)
                OOToolStatus(.stopped)
                OOToolStatus(.idle)
            }
        }
    }
}
