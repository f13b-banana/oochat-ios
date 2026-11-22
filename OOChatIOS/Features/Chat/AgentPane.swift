import ConnectOnionKit
import SwiftUI
import UIKit

/// The top of the agent pane, as on the Mac: the agent's name (tap to rename), its status and short
/// address (tap to copy), and ⋯ for everything else about the agent.
struct AgentPaneHeader: View {
    let agent: SavedAgent
    let isOnline: Bool
    let isStation: Bool
    let actions: AgentPaneHeaderActions
    let topInset: CGFloat

    @State private var didCopy = false

    private var name: String {
        agent.displayName
    }

    var body: some View {
        HStack(spacing: OOSpace.small) {
            VStack(alignment: .leading, spacing: 2) {
                nameButton
                statusLine
            }
            Spacer(minLength: 0)
            menu
        }
        .padding(.leading, OOSpace.small)
        .frame(height: AgentRail.headerHeight)
        .padding(.top, topInset)
    }

    private var nameButton: some View {
        Button(action: rename) {
            Text(name)
                .font(.body.weight(.semibold))
                .foregroundStyle(OOColor.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, OOSpace.tiny + 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterButtonStyle())
        .accessibilityLabel(name)
        .accessibilityHint("Renames the agent")
    }

    private func rename() {
        actions.rename(agent)
    }

    private var statusLine: some View {
        HStack(spacing: OOSpace.tiny + 2) {
            OOSidebarStatusDot(isOnline: isOnline)
            Text(isStation ? "Claude Station" : (isOnline ? "Online" : "Offline"))
                .foregroundStyle(OOColor.inkSecondary)
            // An agent named by its address doesn't repeat it here.
            if let address = agent.shortAddress, address != name {
                Text("·")
                    .foregroundStyle(OOColor.inkTertiary)
                    .accessibilityHidden(true)
                Button(action: copyAddress) {
                    Text(didCopy ? "Copied" : address)
                        .monospacedDigit()
                        .foregroundStyle(didCopy ? OOColor.tintText : OOColor.inkTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "Address copied" : "Copy address")
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .padding(.horizontal, OOSpace.tiny + 2)
    }

    private var menu: some View {
        Menu {
            Button(action: rename) {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                actions.edit(agent)
            } label: {
                Label("Edit Agent", systemImage: "slider.horizontal.3")
            }
            Button(action: copyAddress) {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            if let shareURL = AgentShareURL.url(for: agent.address) {
                ShareLink(item: shareURL) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                Button {
                    actions.showQRCode(shareURL)
                } label: {
                    Label("Show QR Code", systemImage: "qrcode")
                }
            }
            Divider()
            Button(role: .destructive) {
                actions.delete(agent)
            } label: {
                Label("Remove agent…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
                .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More for \(name)")
    }

    private func copyAddress() {
        UIPasteboard.general.string = agent.address
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }
}

struct AgentPaneHeaderActions {
    var rename: (SavedAgent) -> Void
    var edit: (SavedAgent) -> Void
    var showQRCode: (URL) -> Void
    var delete: (SavedAgent) -> Void
}

/// A section title in the agent pane, which folds its section when it has `toggle`. Secondary
/// ink, as on the Mac: the system's own section style is too dim on the green surface. 44 pt to
/// hit, its text kept low so it sits with the rows it heads.
struct AgentPaneSectionHeader: View {
    let title: String
    var isExpanded = true
    var toggle: (() -> Void)?

    var body: some View {
        if let toggle {
            Button(action: toggle) {
                label(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the section" : "Shows the section")
        } else {
            label(showsChevron: false)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: OOSpace.tiny) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(OOColor.inkSecondary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(OOColor.inkTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
        .padding(.bottom, OOSpace.tiny)
        .frame(maxWidth: .infinity, minHeight: ooMinimumTarget, alignment: .bottomLeading)
        .contentShape(Rectangle())
    }
}

/// A plain pane row with its icon: New chat, a Work Room, a skill, the agent's actions.
struct AgentPaneActionRow: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OOSpace.medium) {
                Image(systemName: systemImage)
                    .font(isProminent ? .body.weight(.semibold) : .body)
                    .foregroundStyle(isProminent ? OOColor.primary : OOColor.inkSecondary)
                    .frame(width: 22)
                Text(title)
                    .font(isProminent ? .body.weight(.semibold) : .body)
                    .foregroundStyle(OOColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .background(
                isSelected ? OOColor.currentTint : Color.clear,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Show all (n)" opens the rest; "Show less" folds back.
struct AgentPaneShowAllRow: View {
    let isShowingAll: Bool
    let total: Int
    var indent: CGFloat = OOSidebarMetrics.chatIndent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isShowingAll ? "Show less" : "Show all (\(total))")
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
                .padding(.leading, max(indent, OOSidebarMetrics.horizontalPadding))
                .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// A row of the agent pane's list: no system separator or background, the pane's own insets.
    func paneRow(top: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(
            top: top,
            leading: SidebarMetrics.compactRowLeading,
            bottom: 0,
            trailing: SidebarMetrics.compactRowTrailing
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

extension SavedAgent {
    /// 0x1234...abcd, as the rest of the app shortens an address.
    var shortAddress: String? {
        guard !address.isEmpty else {
            return nil
        }
        guard address.count > 12 else {
            return address
        }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }
}
