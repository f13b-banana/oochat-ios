import SwiftUI

/// The Work Room Card: the timeline entry that stands for a Provider Invocation.
/// It shows only the Provider, the allowed task title, the status, one allowed summary and at most one small
/// real preview, never prompts, commands, paths, ids or output, and has exactly one action.
public struct OOWorkRoomCard: View {
    private let workRoom: WorkRoom
    private let onOpen: () -> Void
    private let onDecide: ((WorkRoomDecision) -> Void)?

    /// `onOpen` is the app's navigation to the Work Room: a push on iOS, the detail pane on macOS. It is also
    /// what the Decision Strip's "Review details in Work Room" does. `onDecide` is the app's answer to the
    /// store (`WorkRoomStore.decide`); without it the card never shows a Decision Strip.
    public init(workRoom: WorkRoom, onOpen: @escaping () -> Void, onDecide: ((WorkRoomDecision) -> Void)? = nil) {
        self.workRoom = workRoom
        self.onOpen = onOpen
        self.onDecide = onDecide
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OOSpace.small) {
            HStack(spacing: OOSpace.small) {
                OOProviderBadge(provider: workRoom.provider)
                Spacer(minLength: OOSpace.small)
                HStack(spacing: 6) {
                    OOToolStatus(workRoom.status.toolState, isAwaitingApproval: workRoom.status == .awaitingApproval)
                        .accessibilityHidden(true)
                    Text(workRoom.status.label)
                        .font(.caption)
                        .foregroundStyle(OOColor.inkSecondary)
                }
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(OOColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let summary = workRoom.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview = workRoom.preview {
                OOWorkRoomPreview(screenshot: preview)
                    .frame(maxWidth: 160)
            }
            if let approval = strip, let onDecide {
                OODecisionStrip(approval: approval, onDecide: onDecide, onReview: onOpen)
            } else {
                Button("Open Work Room", action: onOpen)
                    .buttonStyle(.ooSecondary)
                    .accessibilityLabel("Open Work Room")
                    .accessibilityHint("\(workRoom.provider.displayName): \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ooCard()
        .accessibilityElement(children: .contain)
    }

    /// Only a verified Work Room scope that can be allowed once gets a Decision Strip. Anything else keeps the
    /// plain card: the card never offers an Allow it cannot back, and the decision happens in the Work Room.
    private var strip: WorkRoomApproval? {
        workRoom.approval.flatMap { $0.offersAllow ? $0 : nil }
    }

    private var title: String {
        workRoom.displayTitle
    }
}

/// The Provider's name on its tint, shared by the Work Room Card and the Work Room header.
struct OOProviderBadge: View {
    let provider: OIPProvider

    var body: some View {
        let isClaude = provider == .claudeCode
        return Text(provider.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isClaude ? OOColor.claudeCodeTintText : OOColor.codexTintText)
            .padding(.horizontal, OOSpace.small)
            .padding(.vertical, 2)
            .background(isClaude ? OOColor.claudeCodeTint : OOColor.codexTint, in: Capsule())
    }
}

extension OIPProviderStatus {
    var toolState: OOToolStatus.State {
        switch self {
        case .starting, .running, .awaitingApproval: .running
        case .completed: .done
        case .failed: .failed
        case .cancelled: .stopped
        }
    }
}

#Preview("Work Room Card") {
    OOPreviewPair {
        VStack(spacing: 12) {
            OOWorkRoomCard(
                workRoom: WorkRoom(
                    id: "claude_code:station", toolCallID: "claude_station:preview", provider: .claudeCode,
                    title: "Claude Code session", status: .running, summary: "Claude Code is working",
                    activities: [], messages: []
                ),
                onOpen: {}
            )
            OOWorkRoomCard(
                workRoom: WorkRoom(
                    id: "codex:preview", toolCallID: "preview", provider: .codex,
                    title: "Build and verify the requested C program", status: .failed,
                    summary: "The provider reported an error", activities: [], messages: []
                ),
                onOpen: {}
            )
        }
        .frame(width: 320)
    }
}
