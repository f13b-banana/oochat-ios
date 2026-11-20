import SwiftUI

/// Sizes for the one sidebar both apps share: 28 pt rows for a pointer, 44 pt for a finger.
public enum OOSidebarMetrics {
    #if os(macOS)
    public static let rowHeight: CGFloat = 28
    #else
    public static let rowHeight: CGFloat = 44
    #endif
    public static let rowCornerRadius: CGFloat = OORadius.large
    public static let horizontalPadding: CGFloat = OOSpace.small
    /// Chats sit a step in from their agent's name (which starts at 24), so the nesting reads
    /// from position alone, without icons.
    public static let chatIndent: CGFloat = 32
    public static let dotSize: CGFloat = 8

    /// The sidebar's whole type scale: names and titles at one size, everything quieter at one
    /// smaller size. The Mac's text styles run smaller than iOS's, so it steps up a style.
    #if os(macOS)
    public static let titleFont: Font = .body
    public static let metaFont: Font = .subheadline
    public static let previewFont: Font = .subheadline
    #else
    public static let titleFont: Font = .subheadline
    public static let metaFont: Font = .caption
    public static let previewFont: Font = .footnote
    #endif
}

/// An agent's reachability: filled green when online, a hollow grey ring when not.
public struct OOSidebarStatusDot: View {
    private let isOnline: Bool

    public init(isOnline: Bool) {
        self.isOnline = isOnline
    }

    public var body: some View {
        Group {
            if isOnline {
                Circle().fill(OOColor.live)
            } else {
                Circle().strokeBorder(OOColor.inkTertiary, lineWidth: 1.5)
            }
        }
        .frame(width: OOSidebarMetrics.dotSize, height: OOSidebarMetrics.dotSize)
        .accessibilityLabel(isOnline ? "Online" : "Offline")
    }
}

/// Where an agent header's fold chevron sits: always at the end (iOS), or, with a pointer, in
/// place of the status dot while the row is hovered (as Claude's sidebar does).
public enum OOSidebarDisclosure: Sendable {
    case trailing
    case leadingOnHover
    /// No chevron: the row opens something rather than folding (a Claude Station).
    case hidden
}

/// A folding agent group's header: status dot, name, then what a folded group would hide.
/// `actions` is each app's own ＋ and ⋯; they stay their own controls, apart from the
/// name, which folds the group through `onToggle`.
public struct OOSidebarAgentHeader<Actions: View>: View {
    private let name: String
    private let isOnline: Bool
    private let isExpanded: Bool
    private let chatCount: Int
    private let needsYou: Bool
    private let isCurrent: Bool
    private let onToggle: (() -> Void)?
    private let disclosure: OOSidebarDisclosure
    private let isHovered: Bool
    private let showsCount: Bool
    private let isStation: Bool
    private let actions: Actions

    public init(
        name: String,
        isOnline: Bool,
        isExpanded: Bool,
        chatCount: Int,
        needsYou: Bool,
        isCurrent: Bool = false,
        onToggle: (() -> Void)? = nil,
        disclosure: OOSidebarDisclosure = .trailing,
        isHovered: Bool = false,
        showsCount: Bool = true,
        isStation: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.isStation = isStation
        self.disclosure = disclosure
        self.isHovered = isHovered
        self.showsCount = showsCount
        self.name = name
        self.isOnline = isOnline
        self.isExpanded = isExpanded
        self.chatCount = chatCount
        self.needsYou = needsYou
        self.isCurrent = isCurrent
        self.onToggle = onToggle
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: OOSpace.tiny) {
            toggleArea {
                HStack(spacing: OOSpace.small) {
                    leadingMark
                    // The agent you're on reads in the selection green, so New chat's target is plain.
                    Text(name)
                        .font(OOSidebarMetrics.titleFont.weight(.semibold))
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // A Claude Station says so after its name, in the Claude Code tint, on the
                    // same line so the row keeps its height.
                    if isStation {
                        Text("Station")
                            .font(OOSidebarMetrics.metaFont.weight(.semibold))
                            .foregroundStyle(OOColor.claudeCodeTintText)
                            .fixedSize()
                    }
                    Spacer(minLength: OOSpace.small)
                    // Open, the chat row itself says it; folded, the header must.
                    if needsYou && !isExpanded {
                        Image(systemName: "hand.raised.fill")
                            .font(OOSidebarMetrics.metaFont)
                            .foregroundStyle(OOColor.decisionMark)
                    }
                    // A folded group says how much it holds; an open one shows it.
                    if showsCount && !isExpanded && chatCount > 0 {
                        Text("\(chatCount)")
                            .font(OOSidebarMetrics.titleFont.weight(.medium).monospacedDigit())
                            .foregroundStyle(OOColor.inkSecondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenLabel)
            .accessibilityValue(disclosure == .hidden ? "" : (isExpanded ? "expanded" : "collapsed"))
            .accessibilityAddTraits(.isHeader)

            actions

            if disclosure == .trailing {
                toggleArea {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OOColor.inkTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(maxHeight: .infinity)
                }
                // The name already folds the group for VoiceOver.
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
        .frame(minHeight: OOSidebarMetrics.rowHeight)
    }

    /// The status dot, or while hovered with `.leadingOnHover`, the fold chevron in its place.
    /// Both sit in the dot's width so the name never moves.
    @ViewBuilder
    private var leadingMark: some View {
        if disclosure == .leadingOnHover && isHovered {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(OOColor.inkSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: OOSidebarMetrics.dotSize)
        } else {
            OOSidebarStatusDot(isOnline: isOnline)
                .frame(width: OOSidebarMetrics.dotSize)
        }
    }

    private var nameColor: Color {
        if isCurrent {
            return OOColor.tintText
        }
        return isOnline ? OOColor.ink : OOColor.inkSecondary
    }

    @ViewBuilder
    private func toggleArea<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let onToggle {
            Button(action: onToggle) {
                content().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private var spokenLabel: String {
        var parts = [name]
        if isStation {
            parts.append("Claude Station")
        }
        parts.append(isOnline ? "online" : "offline")
        if isCurrent {
            parts.append("current agent")
        }
        if needsYou && !isExpanded {
            parts.append("a chat needs attention")
        }
        if !isExpanded && chatCount > 0 {
            parts.append(chatCount == 1 ? "1 chat" : "\(chatCount) chats")
        }
        return parts.joined(separator: ", ")
    }
}

public extension OOSidebarAgentHeader where Actions == EmptyView {
    init(
        name: String,
        isOnline: Bool,
        isExpanded: Bool,
        chatCount: Int,
        needsYou: Bool,
        isCurrent: Bool = false,
        onToggle: (() -> Void)? = nil
    ) {
        self.init(
            name: name,
            isOnline: isOnline,
            isExpanded: isExpanded,
            chatCount: chatCount,
            needsYou: needsYou,
            isCurrent: isCurrent,
            onToggle: onToggle
        ) {
            EmptyView()
        }
    }
}

/// One chat: its title, then the time, or what's happening in place of the time. An optional
/// quiet preview line underneath (off unless the person turns it on in Settings).
public struct OOSidebarChatRow: View {
    private let title: String
    private let lastActivity: Date?
    private let status: SidebarChatStatus?
    private let preview: String?
    private let isSelected: Bool
    private let isPinned: Bool
    private let isUnread: Bool
    private let hidesTime: Bool
    private let indent: CGFloat

    /// `isUnread`: a reply arrived while you were elsewhere; the title goes semibold, as in Mail.
    /// `hidesTime`: the caller puts its ⋯ there (hover, selection). A status is never hidden.
    public init(
        title: String,
        lastActivity: Date?,
        status: SidebarChatStatus? = nil,
        preview: String? = nil,
        isSelected: Bool = false,
        isPinned: Bool = false,
        isUnread: Bool = false,
        hidesTime: Bool = false,
        indent: CGFloat = OOSidebarMetrics.chatIndent
    ) {
        self.hidesTime = hidesTime
        self.title = title
        self.lastActivity = lastActivity
        self.status = status
        self.preview = preview
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.indent = indent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OOSpace.tiny + 2) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(OOColor.inkTertiary)
                }
                Text(title)
                    .font(OOSidebarMetrics.titleFont.weight(isUnread ? .semibold : .regular))
                    .foregroundStyle(OOColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: OOSpace.small)
                // The title gives way first: the time or status is never cut.
                trailing
                    .fixedSize()
                    .layoutPriority(1)
            }
            if let preview, !preview.isEmpty {
                Text(preview)
                    .font(OOSidebarMetrics.previewFont)
                    .foregroundStyle(OOColor.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, indent)
        .padding(.trailing, OOSidebarMetrics.horizontalPadding)
        .padding(.vertical, preview == nil ? 0 : OOSpace.tiny)
        .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
        .background(
            isSelected ? OOColor.currentTint : Color.clear,
            in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var trailing: some View {
        if let status {
            HStack(spacing: OOSpace.tiny) {
                if let systemImage = status.systemImage {
                    Image(systemName: systemImage)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(status.label)
            }
            .font(OOSidebarMetrics.metaFont)
            .foregroundStyle(status.tint)
        } else if let lastActivity, !hidesTime {
            // Refreshes once a minute so "2m" doesn't go stale while the list is open.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(SidebarTime.relative(lastActivity, now: context.date))
                    .font(OOSidebarMetrics.metaFont.monospacedDigit())
                    .foregroundStyle(OOColor.inkTertiary)
            }
        }
    }

    private var spokenLabel: String {
        var parts = [title]
        if isPinned {
            parts.append("pinned")
        }
        if isUnread {
            parts.append("new reply")
        }
        if let status {
            parts.append(status.spokenLabel)
        } else if let lastActivity {
            parts.append(SidebarTime.relative(lastActivity))
        }
        if let preview, !preview.isEmpty {
            parts.append(preview)
        }
        return parts.joined(separator: ", ")
    }
}

/// The amber line at the top of the sidebar while any chat needs you. With `isExpanded` set it
/// shows a chevron: the caller lists the chats under it when open.
public struct OOSidebarAttentionLine: View {
    private let text: String
    private let isExpanded: Bool?
    private let drawsBackground: Bool

    /// `drawsBackground: false` when the caller wraps it, with its chats, in one amber panel.
    public init(_ text: String, isExpanded: Bool? = nil, drawsBackground: Bool = true) {
        self.text = text
        self.isExpanded = isExpanded
        self.drawsBackground = drawsBackground
    }

    public var body: some View {
        HStack(spacing: OOSpace.small) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(OOColor.decisionMark)
            Text(text)
                .foregroundStyle(OOColor.decisionText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let isExpanded {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OOColor.decisionText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Pulled in from the panel's edge so it sits with the line, not in the corner.
                    .padding(.trailing, OOSpace.tiny)
            }
        }
        .font(OOSidebarMetrics.previewFont.weight(.medium))
        .padding(.leading, OOSidebarMetrics.horizontalPadding)
        .padding(.trailing, OOSidebarMetrics.horizontalPadding + OOSpace.tiny)
        .frame(minHeight: OOSidebarMetrics.rowHeight)
        .background(
            drawsBackground ? OOColor.decisionFill : Color.clear,
            in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded.map { $0 ? "expanded" : "collapsed" } ?? "")
    }
}
