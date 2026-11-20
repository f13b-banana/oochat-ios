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
    @State private var isCommandExpanded = false
    private static let commandArgumentKeys: Set<String> = ["cmd", "command", "script"]

    private var request: ToolApprovalRequest {
        approval.request
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let description = request.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            commandPreview

            argumentList

            if !request.batchRemaining.isEmpty {
                Text("\(request.batchRemaining.count) more action\(request.batchRemaining.count == 1 ? "" : "s") waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            actionRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(.separator).opacity(0.18), lineWidth: 0.5)
        )
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
        HStack(alignment: .top, spacing: 8) {
            if commandArgument != nil {
                Image(systemName: isCommandExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(toolTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let toolSubtitle {
                        Text(toolSubtitle)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                permissionStatusBadge
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var permissionStatusBadge: some View {
        Text("Needs permission")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                AppTheme.primary.opacity(0.10),
                in: Capsule()
            )
    }

    @ViewBuilder
    private var commandPreview: some View {
        if let commandArgument, isCommandExpanded {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(commandArgument)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
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
                .padding(10)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
        }
    }

    private var actionRow: some View {
        VStack(spacing: 8) {
            Button {
                onAllowOnce()
            } label: {
                Text("Allow once")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        AppTheme.primary,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
            .buttonStyle(AppPressButtonStyle(pressedScale: 0.98, pressedOpacity: 0.88))
            .accessibilityIdentifier("approval.allowOnce.\(request.id)")

            Button {
                onTrustSession()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(trustTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    Text("For this session")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .buttonStyle(AppPressButtonStyle(pressedScale: 0.98, pressedOpacity: 0.88))
            .accessibilityIdentifier("approval.trustSession.\(request.id)")

            HStack(spacing: 0) {
                Button {
                    onSkip()
                } label: {
                    Text("Skip tool")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(AppPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.78))
                .accessibilityIdentifier("approval.skip.\(request.id)")

                Divider()
                    .frame(height: 20)

                Button(role: .destructive) {
                    onStop()
                } label: {
                    Text("Stop response")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.destructive)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(AppPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.78))
                .accessibilityIdentifier("approval.stop.\(request.id)")

                Divider()
                    .frame(height: 20)

                Button {
                    onExplain()
                } label: {
                    Text("Explain")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(AppPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.78))
                .accessibilityIdentifier("approval.explain.\(request.id)")
            }
            .background(
                Color(.tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
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
