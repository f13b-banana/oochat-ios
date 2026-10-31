import SwiftUI

enum ToolCallPresentation {
    case standalone
    case grouped
}

struct ToolCallView: View {
    let message: ChatMessage
    var presentation: ToolCallPresentation = .standalone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    init(message: ChatMessage, presentation: ToolCallPresentation = .standalone) {
        self.message = message
        self.presentation = presentation
        // a direct run was asked for by hand, answer is shown without a tap
        _isExpanded = State(initialValue: message.isDirectExec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton

            if isExpanded {
                Divider()
                    .padding(.leading, dividerInset)

                VStack(alignment: .leading, spacing: ToolCallMetrics.detailSpacing) {
                    if !argumentsDescription.isEmpty {
                        detail(label: "Input", value: argumentsDescription)
                    }

                    if !message.content.isEmpty {
                        detail(
                            label: toolState == .failed ? "Error" : "Result",
                            value: message.content,
                            isError: toolState == .failed
                        )
                    }
                }
                .padding(.horizontal, detailHorizontalPadding)
                .padding(.vertical, ToolCallMetrics.detailVerticalPadding)
                .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            presentation == .standalone ? Color(.secondarySystemBackground) : Color.clear,
            in: RoundedRectangle(cornerRadius: ToolCallMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ToolCallMetrics.cornerRadius, style: .continuous)
                .stroke(
                    presentation == .standalone ? borderColor : Color.clear,
                    lineWidth: ToolCallMetrics.borderWidth
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: ToolCallMetrics.cornerRadius, style: .continuous))
        .animation(AppMotion.stateChange(reduceMotion: reduceMotion), value: message.toolState)
        .accessibilityIdentifier("toolCall.\(message.id)")
    }

    private var headerButton: some View {
        Button {
            withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: ToolCallMetrics.headerSpacing) {
                statusIcon

                headerCopy

                Spacer(minLength: ToolCallMetrics.minimumTrailingSpacing)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: ToolCallMetrics.chevronWidth)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, headerHorizontalPadding)
            .padding(.vertical, headerVerticalPadding)
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.99, pressedOpacity: 0.90))
        .accessibilityLabel("Tool call: \(toolTitle)")
        .accessibilityValue("\(statusLabel), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityHint(isExpanded ? "Collapses tool details" : "Shows tool input and result")
    }

    private var summary: String {
        ToolActionSummary.completed(
            toolName: message.toolName ?? "tool",
            arguments: message.toolArguments ?? [:]
        )
    }

    @ViewBuilder
    private var headerCopy: some View {
        if presentation == .grouped {
            Text(summary)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if toolState == .completed {
                    Text(toolTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 5) {
                        Text(toolTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text(statusLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusTint)
                    }
                    .lineLimit(1)
                }

                Text(summary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var argumentsDescription: String {
        ToolActionSummary.argumentsDescription(message.toolArguments ?? [:])
    }

    private var toolTitle: String {
        let name = (message.toolName ?? "Tool")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return message.isDirectExec ? "Direct \u{00B7} \(name)" : name
    }

    private var toolState: ToolCallState {
        message.toolState ?? .running
    }

    private var statusIcon: some View {
        ToolCallStatusIcon(
            state: toolState,
            completedSystemName: ToolCallIconography.systemName(for: message),
            size: iconSize
        )
    }

    private var statusLabel: String {
        switch toolState {
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    private var statusTint: Color {
        switch toolState {
        case .running:
            return AppTheme.primary
        case .completed:
            return Color(.secondaryLabel)
        case .failed:
            return AppTheme.destructive
        }
    }

    private var borderColor: Color {
        toolState == .failed
            ? AppTheme.destructive.opacity(0.24)
            : Color(.separator).opacity(0.18)
    }

    private var headerHorizontalPadding: CGFloat {
        presentation == .standalone ? ToolCallMetrics.horizontalPadding : 0
    }

    private var headerVerticalPadding: CGFloat {
        presentation == .standalone
            ? ToolCallMetrics.verticalPadding
            : ToolCallMetrics.groupedVerticalPadding
    }

    private var detailHorizontalPadding: CGFloat {
        presentation == .standalone ? ToolCallMetrics.detailPadding : 0
    }

    private var iconSize: CGFloat {
        presentation == .standalone ? ToolCallMetrics.iconSize : ToolCallMetrics.groupedIconSize
    }

    private var dividerInset: CGFloat {
        headerHorizontalPadding + iconSize + ToolCallMetrics.headerSpacing
    }
}

struct ToolCallGroupView: View {
    let messages: [ChatMessage]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader

            if isExpanded {
                Divider()
                    .padding(.leading, ToolCallGroupMetrics.dividerInset)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        ToolCallView(message: message, presentation: .grouped)

                        if index < messages.count - 1 {
                            Divider()
                                .padding(.leading, ToolCallGroupMetrics.itemDividerInset)
                        }
                    }
                }
                .padding(.horizontal, ToolCallGroupMetrics.contentHorizontalPadding)
                .padding(.bottom, ToolCallGroupMetrics.contentBottomPadding)
                .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: ToolCallGroupMetrics.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ToolCallGroupMetrics.cornerRadius, style: .continuous)
                .stroke(groupBorderColor, lineWidth: ToolCallGroupMetrics.borderWidth)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: ToolCallGroupMetrics.cornerRadius, style: .continuous)
        )
        .animation(AppMotion.stateChange(reduceMotion: reduceMotion), value: statusSignature)
        .accessibilityIdentifier("toolCallGroup.\(messages.first?.id ?? "unknown")")
    }

    private var groupHeader: some View {
        Button {
            withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: ToolCallGroupMetrics.headerSpacing) {
                groupStatusIcon

                Text(ToolCallGroupSummary.title(for: messages))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)

                Spacer(minLength: ToolCallGroupMetrics.minimumTrailingSpacing)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: ToolCallGroupMetrics.chevronWidth)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, ToolCallGroupMetrics.headerHorizontalPadding)
            .padding(.vertical, ToolCallGroupMetrics.headerVerticalPadding)
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.99, pressedOpacity: 0.90))
        .accessibilityLabel(ToolCallGroupSummary.title(for: messages))
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint(isExpanded ? "Collapses tool activity" : "Shows each tool call")
    }

    private var groupStatusIcon: some View {
        ToolCallStatusIcon(
            state: aggregateState,
            completedSystemName: ToolCallIconography.systemName(for: messages.first),
            size: ToolCallGroupMetrics.iconSize
        )
    }

    private var aggregateState: ToolCallState {
        if messages.contains(where: { ($0.toolState ?? .running) == .running }) {
            return .running
        }
        if messages.contains(where: { $0.toolState == .failed }) {
            return .failed
        }
        return .completed
    }

    private var groupBorderColor: Color {
        aggregateState == .failed
            ? AppTheme.destructive.opacity(0.24)
            : Color(.separator).opacity(0.18)
    }

    private var statusSignature: String {
        messages.map { $0.toolState?.rawValue ?? "running" }.joined(separator: "|")
    }
}

private struct ToolCallStatusIcon: View {
    let state: ToolCallState
    let completedSystemName: String
    let size: CGFloat

    var body: some View {
        ZStack {
            statusGlyph
                .id(state.rawValue)
                .transition(.opacity)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.16), value: state.rawValue)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.primary)
        case .completed:
            Image(systemName: completedSystemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.destructive)
        }
    }
}

private enum ToolCallIconography {
    static func systemName(for message: ChatMessage?) -> String {
        let name = (message?.toolName ?? "").lowercased()

        if name.contains("edit") || name.contains("patch") || name.contains("write") {
            return "pencil"
        }
        if name.contains("read") {
            return "doc.text"
        }
        if name.contains("command") || name.contains("exec") || name.contains("shell")
            || name.contains("bash") || name.contains("terminal") {
            return "terminal"
        }
        if name.contains("search") || name.contains("find") || name.contains("grep") {
            return "magnifyingglass"
        }
        if name.contains("list") || name.contains("glob") {
            return "folder"
        }
        return "wrench.and.screwdriver"
    }
}

enum ToolCallGroupSummary {
    static func title(for messages: [ChatMessage]) -> String {
        guard !messages.isEmpty else {
            return "Tool activity"
        }

        if messages.contains(where: { ($0.toolState ?? .running) == .running }) {
            return "Running \(messages.count) tools"
        }

        var orderedCategories: [Category] = []
        var counts: [Category: Int] = [:]

        for message in messages {
            let category = category(for: message)
            if counts[category] == nil {
                orderedCategories.append(category)
            }
            counts[category, default: 0] += 1
        }

        let phrases = orderedCategories.map {
            phrase(for: $0, count: counts[$0, default: 1])
        }
        return sentence(from: phrases)
    }

    private enum Category: Hashable {
        case editedFiles
        case readFiles
        case ranCommands
        case searched
        case listedFiles
        case usedTools
    }

    private static func category(for message: ChatMessage) -> Category {
        let name = (message.toolName ?? "").lowercased()

        if name.contains("edit") || name.contains("patch") || name.contains("write") {
            return .editedFiles
        }
        if name.contains("read") {
            return .readFiles
        }
        if name.contains("command") || name.contains("exec") || name.contains("shell")
            || name.contains("bash") || name.contains("terminal") {
            return .ranCommands
        }
        if name.contains("search") || name.contains("find") || name.contains("grep") {
            return .searched
        }
        if name.contains("list") || name.contains("glob") {
            return .listedFiles
        }
        return .usedTools
    }

    private static func phrase(for category: Category, count: Int) -> String {
        switch category {
        case .editedFiles:
            return count == 1 ? "edited a file" : "edited files"
        case .readFiles:
            return count == 1 ? "read a file" : "read files"
        case .ranCommands:
            return count == 1 ? "ran a command" : "ran commands"
        case .searched:
            return "searched"
        case .listedFiles:
            return "listed files"
        case .usedTools:
            return count == 1 ? "used a tool" : "used tools"
        }
    }

    private static func sentence(from phrases: [String]) -> String {
        let joined: String
        switch phrases.count {
        case 0:
            return "Tool activity"
        case 1:
            joined = phrases[0]
        case 2:
            joined = "\(phrases[0]) and \(phrases[1])"
        default:
            joined = "\(phrases.dropLast().joined(separator: ", ")), and \(phrases.last!)"
        }

        return joined.prefix(1).uppercased() + String(joined.dropFirst())
    }
}

private extension ToolCallView {
    func detail(label: String, value: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isError ? AppTheme.destructive : Color.secondary)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? AppTheme.destructive : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ToolCallMetrics.codePadding)
                .background(
                    isError
                        ? AppTheme.destructive.opacity(0.07)
                        : Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: ToolCallMetrics.codeCornerRadius, style: .continuous)
                )
        }
    }
}

private enum ToolCallMetrics {
    static let cornerRadius: CGFloat = 14
    static let borderWidth: CGFloat = 0.5
    static let headerSpacing: CGFloat = 11
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let groupedVerticalPadding: CGFloat = 9
    static let minimumTrailingSpacing: CGFloat = 8
    static let chevronWidth: CGFloat = 16
    static let iconSize: CGFloat = 28
    static let groupedIconSize: CGFloat = 24
    static let detailSpacing: CGFloat = 12
    static let detailPadding: CGFloat = 12
    static let detailVerticalPadding: CGFloat = 10
    static let codePadding: CGFloat = 10
    static let codeCornerRadius: CGFloat = 10
}

private enum ToolCallGroupMetrics {
    static let cornerRadius: CGFloat = 14
    static let borderWidth: CGFloat = 0.5
    static let headerSpacing: CGFloat = 11
    static let headerHorizontalPadding: CGFloat = 12
    static let headerVerticalPadding: CGFloat = 10
    static let minimumTrailingSpacing: CGFloat = 8
    static let chevronWidth: CGFloat = 16
    static let iconSize: CGFloat = 28
    static let dividerInset: CGFloat = headerHorizontalPadding + iconSize + headerSpacing
    static let itemDividerInset: CGFloat = 24 + ToolCallMetrics.headerSpacing
    static let contentHorizontalPadding: CGFloat = 12
    static let contentBottomPadding: CGFloat = 4
}
