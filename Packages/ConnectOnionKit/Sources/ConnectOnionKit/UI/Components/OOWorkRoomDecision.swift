import SwiftUI

/// Action, scope, reason and risk of a Provider approval, one short line each.
private struct OOApprovalFacts: View {
    let approval: WorkRoomApproval

    var body: some View {
        VStack(alignment: .leading, spacing: OOSpace.tiny) {
            fact("Scope", approval.scope)
            fact("Reason", approval.reason)
            fact("Risk", approval.risk)
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        (Text("\(label): ").fontWeight(.semibold) + Text(verbatim: value))
            .font(.subheadline)
            .foregroundStyle(OOColor.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Decision Strip: the bounded approval control on a Work Room Card. It is shown only for a verified
/// Work Room scope and offers Allow once, Reject this request and Review details in Work Room, nothing wider.
struct OODecisionStrip: View {
    let approval: WorkRoomApproval
    let onDecide: (WorkRoomDecision) -> Void
    let onReview: () -> Void

    var body: some View {
        OONotice(.decision, title: approval.action) {
            OOApprovalFacts(approval: approval)
            VStack(spacing: OOSpace.small) {
                Button("Allow once") { onDecide(.allowOnce) }
                    .buttonStyle(.ooPrimary)
                Button("Reject this request") { onDecide(.reject) }
                    .buttonStyle(.ooSecondary)
                Button("Review details in Work Room", action: onReview)
                    .buttonStyle(.ooQuiet())
            }
        }
    }
}

/// The Work Room decision: replaces the status sentence while a Provider approval waits. It lists the
/// affected file names on one line that scrolls, so the choices stay reachable at 320pt, and says when no
/// change preview exists instead of inventing one.
struct OOWorkRoomDecision: View {
    let approval: WorkRoomApproval
    let onDecide: ((WorkRoomDecision) -> Void)?

    var body: some View {
        OONotice(.decision, title: approval.action) {
            OOApprovalFacts(approval: approval)
            if !approval.files.isEmpty {
                VStack(alignment: .leading, spacing: OOSpace.tiny) {
                    Text("Affected files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OOColor.inkSecondary)
                    ScrollView(.horizontal) {
                        Text(verbatim: approval.files.joined(separator: "  "))
                            .font(OOFont.mono(size: 12, relativeTo: .caption))
                            .foregroundStyle(OOColor.ink)
                            .fixedSize()
                    }
                }
            }
            Text("Change preview unavailable")
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
            Text(OOApprovalDisclosure.providerConsequence(approval.classification))
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            buttons
        }
    }

    @ViewBuilder private var buttons: some View {
        if let resolution = approval.resolution {
            Text(resolution)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OOColor.decisionText)
        } else if let onDecide {
            VStack(spacing: OOSpace.small) {
                if approval.offersAllow {
                    Button("Allow once") { onDecide(.allowOnce) }
                        .buttonStyle(.ooPrimary)
                }
                if approval.offersReject {
                    Button("Reject this request") { onDecide(.reject) }
                        .buttonStyle(.ooSecondary)
                }
            }
        }
    }
}

#Preview("Decision") {
    let approval = WorkRoomApproval(
        id: "approval-1", action: "Make workspace file changes", scope: "This Work Room only",
        reason: "Apply the requested workspace file changes", classification: .workroom,
        files: ["sort.c", "test_sort_with_a_very_long_name_that_needs_to_scroll_sideways.c"], phase: .pending,
        allowOnce: true, isAwaitingApproval: true
    )
    return OOPreviewPair {
        VStack(spacing: 12) {
            OODecisionStrip(approval: approval, onDecide: { _ in }, onReview: {})
            OOWorkRoomDecision(approval: approval, onDecide: { _ in })
        }
        .frame(width: 320)
    }
}
