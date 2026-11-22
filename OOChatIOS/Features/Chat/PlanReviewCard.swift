import ConnectOnionKit
import SwiftUI

struct PlanReviewCard: View {
    let review: PendingPlanReview
    var onApprove: () -> Void
    var onRequestChanges: (String?) -> Void
    var onDiscard: () -> Void

    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: OOSpace.medium) {
            Label("Review implementation plan", systemImage: "list.bullet.clipboard")
                .font(.headline)
                .foregroundStyle(AppTheme.primary)

            ScrollView {
                MarkdownMessageView(content: review.request.planContent)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .padding(OOSpace.medium)
            .background(
                OOColor.paper,
                in: RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
                    .stroke(OOColor.hairline, lineWidth: 1)
            )

            TextField("Feedback for changes (optional)", text: $feedback, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            VStack(spacing: OOSpace.small) {
                Button("Approve & Implement", action: onApprove)
                    .buttonStyle(CardPrimaryButtonStyle())
                    .accessibilityIdentifier("plan.approve.\(review.id)")

                Button("Request Changes") {
                    onRequestChanges(feedback)
                }
                .buttonStyle(CardSecondaryButtonStyle())
                .accessibilityIdentifier("plan.requestChanges.\(review.id)")

                Button("Discard plan", action: onDiscard)
                    .buttonStyle(CardQuietButtonStyle())
                    .accessibilityIdentifier("plan.discard.\(review.id)")
            }
        }
        .conversationCard()
    }
}
