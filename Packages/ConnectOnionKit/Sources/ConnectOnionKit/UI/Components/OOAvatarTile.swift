import SwiftUI

/// agent's tile: soft green square, green initial, live dot on its corner
/// from oo-chat components/agent-avatar.tsx
public struct OOAvatarTile: View {
    public enum Size: Sendable {
        /// 32 points, radius 6: sidebar and rows
        case regular
        /// 48 points, radius 8: the agent page
        case large
    }

    private let name: String
    private let address: String?
    private let isOnline: Bool
    private let tileSize: Size

    @ScaledMetric(relativeTo: .subheadline) private var regular: CGFloat = 32
    @ScaledMetric(relativeTo: .title3) private var large: CGFloat = 48

    public init(name: String, address: String? = nil, isOnline: Bool = false, size: Size = .regular) {
        self.name = name
        self.address = address
        self.isOnline = isOnline
        self.tileSize = size
    }

    public var body: some View {
        let isLarge = tileSize == .large
        Text(Self.initial(of: name, address: address))
            .font(isLarge ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(OOColor.tintText)
            .frame(width: isLarge ? large : regular, height: isLarge ? large : regular)
            .background(
                OOColor.currentTint,
                in: RoundedRectangle(cornerRadius: isLarge ? OORadius.large : OORadius.medium, style: .continuous)
            )
            .overlay(alignment: .bottomTrailing) {
                if isOnline {
                    Circle()
                        .fill(OOColor.live)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(OOColor.paper, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }

    /// agentInitial in oo-chat hooks/use-agent-info.ts:
    /// a real name gives its first letter, an address gives its first a to f letter
    static func initial(of name: String, address: String? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, !trimmed.hasPrefix("0x") {
            return String(first).uppercased()
        }
        let hex = (address ?? trimmed).dropFirst(2)
        let letter = hex.first { "abcdefABCDEF".contains($0) } ?? hex.first
        return letter.map { String($0).uppercased() } ?? "A"
    }
}

#Preview("Avatar tile") {
    OOPreviewPair {
        HStack(spacing: 16) {
            OOAvatarTile(name: "research", isOnline: true)
            OOAvatarTile(name: "", address: "0x3f9a")
            OOAvatarTile(name: "writer", isOnline: true, size: .large)
        }
    }
}
