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
    // action is always visible first. The header only folds a long command away after the person has seen it
    @State private var isCommandExpanded = true
    @State private var isConfirmingTrust = false
    private static let commandArgumentKeys: Set<String> = ["cmd", "command", "script"]

    private var request: ToolApprovalRequest {
        approval.request
    }

    var body: some View {
        // update spacing to OOSpace.medium
        VStack(alignment: .leading, spacing: OOSpace.medium) {
            header

            if let description = request.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    // update foreground colour to be ink secondary as defined in OOColor
                    .foregroundStyle(OOColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            commandPreview
            argumentList

            // Create stack for card field labels to allow user for permission
            VStack(alignment: .leading, spacing: OOSpace.small) {
                CardFieldLabel(label: "Scope", text: ApprovalDisclosure.consequence(for: request))
                CardFieldLabel(label: "If you allow", text: ApprovalDisclosure.consequence(for: request))
            }
            if !request.batchRemaining.isEmpty {
                Text("\(request.batchRemaining.count) more action\(request.batchRemaining.count == 1 ? "" : "s") waiting")
                    .font(.caption)
                    // update foreground colour to be ink secondary as defined in OOColor
                    .foregroundStyle(OOColor.inkSecondary)
            }
            actionRow
        }
        .conversationCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permission requested for \(request.tool)")
    }

    @ViewBuilder
    private var header: some View {
        if commandArgument != nil {
            Button {
                withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                    isCommandExpanded.toggle()
                }
            } label: {
                headerContent
            }
            .buttonStyle(AppPressButtonStyle(pressedScale: 0.99, pressedOpacity: 0.88))
            .accessibilityValue(isCommandExpanded ? "expanded" : "collapsed")
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(alignment: .top, spacing: OOSpace.small) {
            if commandArgument != nil {
                Image(systemName: isCommandExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OOColor.inkSecondary)
                    .frame(width: 10)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }

            // change spacing from 6 to 4
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(toolTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(OOColor.ink)
                        .lineLimit(1)

                    if let toolSubtitle {
                        Text(toolSubtitle)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(OOColor.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // permissionStatusBadge
                // Add needs permission text
                Text("Needs permission")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OOColor.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
    @ViewBuilder
    private var commandPreview: some View {
        if let commandArgument, isCommandExpanded {
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
            .transition(AppMotion.materialize(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var argumentList: some View {
        let details = ToolActionSummary.argumentsDescription(displayArguments)
        if commandArgument == nil || isCommandExpanded, !details.isEmpty {
            Text(details)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OOSpace.medium)
                .background(codeBackground)
                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
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
                    onExplain()
                } label: {
                    Text("Explain")
                }
                .buttonStyle(CardSecondaryButtonStyle())
                .accessibilityIdentifier("approval.explain.\(request.id)")
            }

            trustSection

            Button(role: .destructive) {
                onStop()
            } label: {
                Text("Stop response")
            }
            .buttonStyle(CardQuietButtonStyle(tint: AppTheme.destructive))
            .accessibilityIdentifier("approval.stop.\(request.id)")
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

                Text(ApprovalDisclosure.trustScope)
                    .font(.footnote)
                    .foregroundStyle(OOColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: OOSpace.small) {
                    Button {
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
                        Text("Trust")
                    }
                    .buttonStyle(CardSecondaryButtonStyle())
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

    private var toolTitle: String {
        if commandArgument != nil {
            return "Command"
        }

        return request.tool
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private var toolSubtitle: String? {
        commandArgument
            ?? request.arguments["path"]?.stringValue
            ?? request.arguments["file"]?.stringValue
            ?? request.arguments["url"]?.stringValue
    }

    private var trustTitle: String {
        guard let commandArgument else {
            return "Trust this tool"
        }

        let trimmedCommand = commandArgument.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCommand.isEmpty, trimmedCommand.count <= 18 {
            return "Trust \(trimmedCommand)"
        }

        return "Trust this command"
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

    /// What this one approval covers.
    static func scope(for request: ToolApprovalRequest) -> String {
        switch effect(for: request) {
        case .runsCommand:
            return "This command, once."
        case .changesFiles, .readsOnly:
            if let path = request.arguments["path"]?.stringValue ?? request.arguments["file"]?.stringValue {
                return "This call only, on \(path)."
            }
            return "This call only."
        case .usesNetwork:
            if let url = request.arguments["url"]?.stringValue {
                return "This call only, to \(url)."
            }
            return "This call only."
        case .other:
            return "This call only."
        }
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

    /// What the wider grant covers; shown on the confirmation step.
    static let trustScope =
        "Requests like this one run without asking until this session ends. You can still stop the response at any time."

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
