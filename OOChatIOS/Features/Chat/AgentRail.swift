import ConnectOnionKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The agent rail, as on the Mac: the onion at the top, level with the agent pane's header, then a
/// tile per agent with Add agent under the last one, and Settings at the foot. The agent the pane
/// shows sits on a soft green plate. Touch and hold a tile to reorder it, or for its menu.
struct AgentRail: View {
    @ObservedObject var viewModel: ChatViewModel
    /// In rail order.
    let agents: [SavedAgent]
    let selectedID: String?
    let safeAreaInsets: EdgeInsets
    let actions: AgentRailActions
    @Environment(\.colorScheme) private var colorScheme
    @State private var draggingAgentID: String?

    static let width: CGFloat = 64
    /// The same height as the agent pane's header, so both columns' first rule is one line.
    static let headerHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            // A mark, not a button: the phone has no Home screen to go back to.
            OOLogo.image
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .frame(maxWidth: .infinity)
                .frame(height: Self.headerHeight)
                .padding(.top, safeAreaInsets.top)
                .accessibilityHidden(true)
            rule
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: OOSpace.tiny) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        tile(for: agent, at: index)
                    }
                    // Right under the last agent, where a new one will appear.
                    AgentRailItem(title: "Add agent", isSelected: false, action: actions.addAgent) {
                        railIcon("plus")
                    }
                }
                .padding(.vertical, OOSpace.small)
                // One drop zone for the whole column: leaving it, or a drag ending, clears the drag,
                // and only a tile's own drag can reorder (text from elsewhere is refused).
                .onDrop(
                    of: [.text],
                    delegate: AgentRailDropDelegate(
                        agentIDs: agents.map(\.id),
                        draggingAgentID: $draggingAgentID,
                        move: actions.move
                    )
                )
            }
            rule
            AgentRailItem(title: "Settings", isSelected: false, action: actions.settings) {
                railIcon("gearshape")
            }
            .padding(.top, OOSpace.small)
            .padding(.bottom, safeAreaInsets.bottom + OOSpace.small)
        }
        .padding(.leading, safeAreaInsets.leading)
        .frame(width: Self.width + safeAreaInsets.leading)
        .background {
            // A shade darker than the agent pane, which is a shade darker than the chat.
            OOColor.surface
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.3 : 0.04))
        }
    }

    private func tile(for agent: SavedAgent, at index: Int) -> some View {
        AgentRailTile(
            agent: agent,
            isSelected: agent.id == selectedID,
            isOnline: viewModel.isAgentOnline(agent),
            isStation: viewModel.isStation(agent),
            needsYou: viewModel.conversations(for: agent).contains {
                viewModel.sidebarStatus(forConversationID: $0.id)?.needsYou == true
            },
            canMoveUp: index > 0,
            canMoveDown: index < agents.count - 1,
            actions: actions
        )
        // Lift a tile and drag it to reorder; the others slide aside as it passes over them.
        .onDrag {
            draggingAgentID = agent.id
            return NSItemProvider(object: agent.id as NSString)
        }
    }

    private var rule: some View {
        OOColor.hairline
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func railIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(OOColor.inkSecondary)
    }
}

/// What the rail asks of the sidebar.
struct AgentRailActions {
    var pick: (SavedAgent) -> Void
    var newChat: (SavedAgent) -> Void
    /// Puts the first agent where the second is.
    var move: (String, String) -> Void
    /// One place up (-1) or down (1).
    var step: (String, Int) -> Void
    var addAgent: () -> Void
    var settings: () -> Void
}

/// A rail slot: a 48 pt plate, green when selected and faint while pressed; the content keeps
/// its shape. Used for Add agent, Settings and, through AgentRailTile, each agent.
struct AgentRailItem<Content: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(AgentRailPlateStyle(isSelected: isSelected))
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AgentRailPlateStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isSelected ? OOColor.currentTint : (configuration.isPressed ? OOColor.hover : Color.clear),
                in: RoundedRectangle(cornerRadius: OORadius.large + 2, style: .continuous)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One agent on the rail: its initial on a soft green square (clay for a Claude Station), the
/// status dot on its corner (filled online, a ring offline), and ✋ when a chat needs you.
struct AgentRailTile: View {
    let agent: SavedAgent
    let isSelected: Bool
    let isOnline: Bool
    let isStation: Bool
    let needsYou: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let actions: AgentRailActions

    private var name: String {
        agent.displayName
    }

    private func pick() {
        actions.pick(agent)
    }

    var body: some View {
        AgentRailItem(title: name, isSelected: isSelected, action: pick) {
            Text(Self.initial(of: name))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isStation ? OOColor.claudeCodeTintText : OOColor.tintText)
                .frame(width: 38, height: 38)
                .background(
                    isStation ? OOColor.claudeCodeTint : OOColor.currentTint,
                    in: RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                )
                // On the selected plate the tile keeps an edge, so it doesn't melt into it.
                .overlay {
                    RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
                        .stroke(isSelected ? OOColor.tintText.opacity(0.35) : Color.clear, lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    OOSidebarStatusDot(isOnline: isOnline)
                        .padding(2)
                        .background(OOColor.surface, in: Circle())
                        .offset(x: 4, y: 4)
                }
                .overlay(alignment: .topTrailing) {
                    if needsYou {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 16, height: 16)
                            .background(OOColor.decisionMark, in: Circle())
                            .overlay(Circle().stroke(OOColor.surface, lineWidth: 2))
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .accessibilityLabel(spokenLabel)
        .accessibilityAction(named: Text("Move Up")) { actions.step(agent.id, -1) }
        .accessibilityAction(named: Text("Move Down")) { actions.step(agent.id, 1) }
        .contextMenu {
            Button {
                actions.newChat(agent)
            } label: {
                if isStation {
                    Label("Open Station", systemImage: "terminal")
                } else {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
            Divider()
            Button {
                actions.step(agent.id, -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)
            Button {
                actions.step(agent.id, 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)
            Divider()
            Button {
                UIPasteboard.general.string = agent.address
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
        }
    }

    private var spokenLabel: String {
        var parts = [name]
        if isStation {
            parts.append("Claude Station")
        }
        parts.append(isOnline ? "online" : "offline")
        if needsYou {
            parts.append("a chat needs attention")
        }
        return parts.joined(separator: ", ")
    }

    /// A name's first letter; for an address-only name ("0x3f9a…"), its first a to f letter, as
    /// the kit's avatar tile does.
    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, !trimmed.hasPrefix("0x") {
            return String(first).uppercased()
        }
        let hex = trimmed.dropFirst(2)
        let letter = hex.first { "abcdefABCDEF".contains($0) } ?? hex.first
        return letter.map { String($0).uppercased() } ?? "A"
    }
}

/// Moves the dragged tile as soon as it passes over another, so the rail shows the new order
/// while you're still dragging. The tile under the pointer comes from its position in the column,
/// as every tile has the same height.
struct AgentRailDropDelegate: DropDelegate {
    let agentIDs: [String]
    @Binding var draggingAgentID: String?
    let move: (String, String) -> Void

    /// A 48 pt slot and the 4 pt gap after it, below the column's 8 pt top padding.
    static let slotHeight: CGFloat = 48 + OOSpace.tiny
    static let topInset: CGFloat = OOSpace.small

    static func index(atY y: CGFloat, count: Int) -> Int? {
        guard count > 0 else {
            return nil
        }
        let slot = Int(((y - topInset) / slotHeight).rounded(.down))
        return min(max(slot, 0), count - 1)
    }

    /// Only a drag that started on a tile, never text dragged in from elsewhere.
    func validateDrop(info: DropInfo) -> Bool {
        draggingAgentID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggingAgentID,
              let index = Self.index(atY: info.location.y, count: agentIDs.count),
              agentIDs[index] != draggingAgentID else {
            return DropProposal(operation: .move)
        }
        let targetID = agentIDs[index]
        withAnimation(.easeOut(duration: 0.2)) {
            move(draggingAgentID, targetID)
        }
        return DropProposal(operation: .move)
    }

    /// Left the rail, or the drag ended somewhere else: a later drag from outside can't reorder.
    func dropExited(info: DropInfo) {
        draggingAgentID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingAgentID = nil
        return true
    }
}

/// The rail's order, kept as agent IDs because the saved list puts the last edited agent first.
/// Agents the order doesn't know yet (new ones) go at the end, oldest first.
enum AgentRailOrder {
    static func ordered(_ agents: [SavedAgent], by ids: [String]) -> [SavedAgent] {
        var rank: [String: Int] = [:]
        for (index, id) in ids.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return agents.sorted { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case let (left?, right?):
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.createdAt < rhs.createdAt
            }
        }
    }

    static func moving(_ id: String, to targetID: String, in ids: [String]) -> [String] {
        guard id != targetID,
              let sourceIndex = ids.firstIndex(of: id),
              let targetIndex = ids.firstIndex(of: targetID) else {
            return ids
        }
        var next = ids
        next.remove(at: sourceIndex)
        next.insert(id, at: targetIndex)
        return next
    }

    /// One place up (-1) or down (1); nothing at either end.
    static func moving(_ id: String, by step: Int, in ids: [String]) -> [String] {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + step) else {
            return ids
        }
        return moving(id, to: ids[index + step], in: ids)
    }

    static func decode(_ stored: String) -> [String] {
        stored.split(separator: ",").map(String.init)
    }

    static func encode(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }
}
