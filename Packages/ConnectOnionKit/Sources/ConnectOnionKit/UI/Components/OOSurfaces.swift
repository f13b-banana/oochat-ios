import SwiftUI

public extension View {
    /// white paper, a hairline and radius 10: cards and sheets
    func ooCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.card, style: .continuous)
        return padding(OOSpace.large)
            .background(OOColor.paper, in: shape)
            .overlay(shape.stroke(OOColor.hairline, lineWidth: 1))
    }

    /// a list row, tinted when it is the current item
    func ooRow(isSelected: Bool = false) -> some View {
        padding(.horizontal, OOSpace.medium)
            .frame(maxWidth: .infinity, minHeight: ooMinimumTarget, alignment: .leading)
            .background(
                isSelected ? OOColor.currentTint : Color.clear,
                in: RoundedRectangle(cornerRadius: OORadius.medium, style: .continuous)
            )
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 11 point upper case label with wide letter spacing, and an optional count
/// from oo-chat app/[address]/page.tsx line 311
public struct OOSectionHeader: View {
    private let title: String
    private let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: OOSpace.small) {
            Text(title.uppercased())
                .foregroundStyle(OOColor.inkSecondary)
                .tracking(0.9)
            if let count {
                Text("\(count)")
                    .font(OOFont.mono(size: 11, relativeTo: .caption2))
                    // O Chat's neutral-400 is 2.48:1, and a count needs 4.5:1
                    .foregroundStyle(OOColor.inkSecondary)
            }
        }
        .font(.caption2.weight(.medium))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Card, row and header") {
    OOPreviewPair {
        VStack(alignment: .leading, spacing: 12) {
            OOSectionHeader("Skills", count: 3)
            Text("Selected row").ooRow(isSelected: true)
            Text("Row").ooRow()
            Text("A card holds one thing.").ooCard()
        }
        .frame(width: 260)
    }
}
