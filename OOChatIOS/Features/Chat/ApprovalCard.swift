import SwiftUI
import ConnectOnionKit

// Card view for pending approval requests.
struct ApprovalCard: View {
    let approval: PendingApproval
    var onAllowOnce: () -> Void
    var onTrustSession: () -> Void
    var onSkip: () -> Void
    var onStop: () -> Void
    var onExplain: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingTrust = false
    // Explain, the session grant and Stop sit behind More, so the card leads with the decision.
    @State private var showsMoreActions = false
    private static let commandArgumentKeys: Set<String> = ["cmd", "command", "script"]

    private var request: ToolApprovalRequest {
        approval.request
    }

    var body: some View {
        // The Kit decision notice: amber eyebrow, a plain sentence saying what will happen,
        // then what allowing it means. The command or arguments follow so the person can check them.
        OONotice(
            .decision,
            title: OOApprovalDisclosure.summary(tool: request.tool, arguments: request.arguments),
            message: ApprovalDisclosure.consequence(for: request)
        ) {
            VStack(alignment: .leading, spacing: OOSpace.medium) {
                if let description = request.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(OOColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                commandPreview
                argumentList

                if !request.batchRemaining.isEmpty {
                    Text("\(request.batchRemaining.count) more action\(request.batchRemaining.count == 1 ? "" : "s") waiting")
                        .font(.caption)
                        .foregroundStyle(OOColor.inkSecondary)
                }
                actionRow
            }
        }
    }

    @ViewBuilder
    private var commandPreview: some View {
        if let commandArgument {
            HStack(alignment: .firstTextBaseline, spacing: OOSpace.small) {
                Text("$")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(OOColor.inkSecondary)

                Text(commandArgument)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(OOColor.ink)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(OOSpace.medium)
            .background(codeBackground)
        }
    }

    @ViewBuilder
    private var argumentList: some View {
        let details = ToolActionSummary.argumentsDescription(displayArguments)
        if !details.isEmpty {
            Text(details)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OOSpace.medium)
                .background(codeBackground)
        }
    }
    // New Code Background
    private var codeBackground: some View {
        RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
            .fill(OOColor.paper)
            .overlay(RoundedRectangle(cornerRadius: OORadius.large, style: .continuous).stroke(OOColor.hairline, lineWidth: 1))
    }

    private var actionRow: some View {
        VStack(spacing: OOSpace.small) {
            Button {
                onAllowOnce()
            } label: {
                Text("Allow once")
            }
            .buttonStyle(CardPrimaryButtonStyle())
            .accessibilityIdentifier("approval.allowOnce.\(request.id)")

            HStack(spacing: OOSpace.small) {
                Button {
                    onSkip()
                } label: {
                    Text("Skip tool")
                }
                .buttonStyle(CardSecondaryButtonStyle())
                .accessibilityIdentifier("approval.skip.\(request.id)")

                Button {
                    withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                        showsMoreActions.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("More")
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsMoreActions ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(CardSecondaryButtonStyle())
                .accessibilityValue(showsMoreActions ? "expanded" : "collapsed")
                .accessibilityIdentifier("approval.more.\(request.id)")
            }

            // Kept open while the trust question is showing, so closing More can't hide it.
            if showsMoreActions || isConfirmingTrust {
                Button {
                    onExplain()
                } label: {
                    Text("Explain")
                }
                .buttonStyle(CardSecondaryButtonStyle())
                .accessibilityIdentifier("approval.explain.\(request.id)")

                trustSection

                Button(role: .destructive) {
                    onStop()
                } label: {
                    Text("Stop response")
                }
                .buttonStyle(CardSecondaryButtonStyle(tint: AppTheme.destructive, stroke: AppTheme.destructive))
                .accessibilityIdentifier("approval.stop.\(request.id)")
            }
        }
    }
    // Allowing once is one decision. Trusting is every later request like it, so the
    // first tap only asks, and the grant is sent from the second.
    @ViewBuilder
    private var trustSection: some View {
        if isConfirmingTrust {
            VStack(alignment: .leading, spacing: OOSpace.small) {
                Text("\(trustTitle) for this session?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OOColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(OOApprovalDisclosure.trustScope(tool: request.tool))
                    .font(.footnote)
                    .foregroundStyle(OOColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: OOSpace.small) {
                    Button(role: .cancel) {
                        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                            isConfirmingTrust = false
                        }
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(CardSecondaryButtonStyle())
                    .accessibilityIdentifier("approval.trustCancel.\(request.id)")

                    Button {
                        isConfirmingTrust = false
                        onTrustSession()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.semibold))
                                .accessibilityHidden(true)
                            // The question above names what is trusted; the button only repeats the verb.
                            Text("Trust")
                        }
                    }
                    // The wider grant is the risky choice: red text and a warning mark, but no
                    // fill, so it never outweighs Cancel or the green Allow once.
                    .buttonStyle(CardSecondaryButtonStyle(tint: OOColor.failureText))
                    .accessibilityLabel("Confirm: \(trustTitle) for this session")
                    .accessibilityIdentifier("approval.trustConfirm.\(request.id)")
                }
            }
            .padding(OOSpace.medium)
            .background(codeBackground)
            .transition(AppMotion.materialize(reduceMotion: reduceMotion))
        } else {
            Button {
                withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                    isConfirmingTrust = true
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(trustTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    Text("For this session")
                        .font(.footnote)
                        .foregroundStyle(OOColor.inkSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(CardSecondaryButtonStyle(alignment: .leading))
            .accessibilityIdentifier("approval.trustSession.\(request.id)")
        }
    }

    // The host trusts the whole tool for the session, not one command, so the title names the tool.
    private var trustTitle: String {
        OOApprovalDisclosure.trustTitle(tool: request.tool)
    }

    private var displayArguments: [String: JSONValue] {
        guard commandArgument != nil else {
            return request.arguments
        }

        return request.arguments.filter { key, _ in
            !Self.commandArgumentKeys.contains(key)
        }
    }

    private var commandArgument: String? {
        request.arguments["cmd"]?.stringValue
            ?? request.arguments["command"]?.stringValue
            ?? request.arguments["script"]?.stringValue
    }
}

// The plain-language lines an approval shows between the action and the buttons.
//
// The host sends a tool name, its arguments and an optional description; it does not
// say what the call will do. These lines are worked out from the name and the
// arguments, so they describe the kind of effect, never a guarantee. Keep the wording
// in step with the 2.1 frames.

enum ApprovalDisclosure {
    enum Effect: Equatable {
        case runsCommand
        case changesFiles
        case usesNetwork
        case readsOnly
        case other
    }

    static func effect(for request: ToolApprovalRequest) -> Effect {
        let name = request.tool.lowercased()
        let hasCommand = ["cmd", "command", "script"].contains { request.arguments[$0]?.stringValue != nil }

        if hasCommand || name.hasPrefix("run") || containsAny(name, ["command", "exec", "shell", "bash", "terminal"]) {
            return .runsCommand
        }
        if containsAny(name, ["write", "edit", "patch", "delete", "remove", "move", "rename", "create"]) {
            return .changesFiles
        }
        if containsAny(name, ["fetch", "http", "browse", "download", "upload", "send"])
            || request.arguments["url"]?.stringValue != nil {
            return .usesNetwork
        }
        if containsAny(name, ["read", "search", "find", "grep", "list", "glob"]) {
            return .readsOnly
        }
        return .other
    }

    /// What happens if the person taps Allow once.
    static func consequence(for request: ToolApprovalRequest) -> String {
        switch effect(for: request) {
        case .runsCommand:
            return "Runs on the agent's host with its permissions. It can change files or settings, and that may not be undoable."
        case .changesFiles:
            return "Changes files on the agent's host. Check the path before you allow it."
        case .usesNetwork:
            return "Sends a request over the network from the agent's host."
        case .readsOnly:
            return "Reads only. Nothing is changed."
        case .other:
            return "The agent runs this tool with the values shown above."
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
