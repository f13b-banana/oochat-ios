import ConnectOnionKit
import SwiftUI

// The strip at the top of a chat when the agent is low on credits (amber) or out of them (red).
// The same view as AgentBalanceNotice on macOS.
struct AgentBalanceNotice: View {
    let balanceUSD: Double?
    let agentAddress: String?

    private var notice: AgentBalance.Notice? {
        AgentBalance.notice(for: balanceUSD)
    }

    private var purchaseURL: URL? {
        guard let agentAddress else { return nil }
        return AgentBalance.topUpURL(agentAddress: agentAddress)
    }

    var body: some View {
        if let notice {
            let isEmpty = notice == .empty
            let text = isEmpty ? OOColor.failureText : OOColor.decisionText

            // The message wraps on a narrow screen; the link stays beside it.
            HStack(spacing: OOSpace.small) {
                message(notice, color: text)
                addCreditsLink(color: text)
                    .fixedSize()
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, OOSpace.large)
            .padding(.vertical, OOSpace.tiny)
            .frame(minHeight: ooMinimumTarget)
            .background(isEmpty ? OOColor.failureFill : OOColor.decisionFill)
            .overlay(alignment: .top) {
                (isEmpty ? OOColor.failureLine : OOColor.decisionLine)
                    .frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agentBalanceNotice")
        }
    }

    private func message(_ notice: AgentBalance.Notice, color: Color) -> some View {
        Text(AgentBalance.message(for: notice))
            .fontWeight(.medium)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func addCreditsLink(color: Color) -> some View {
        if let purchaseURL {
            Link(destination: purchaseURL) {
                Text("Add credits")
                    .fontWeight(.semibold)
                    .underline()
                    .foregroundStyle(color)
                    .padding(.horizontal, OOSpace.tiny)
                    .frame(minHeight: ooMinimumTarget)
                    .contentShape(Rectangle())
            }
        }
    }
}
