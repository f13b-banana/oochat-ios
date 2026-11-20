import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// the agent's address in a mono pill: short until tapped, copied in one press
/// from oo-chat components/agent-address.tsx
public struct OOAddressLabel: View {
    private let address: String
    @State private var isExpanded = false
    @State private var isCopied = false
    @State private var copyReset: Task<Void, Never>?

    public init(_ address: String) {
        self.address = address
    }

    public var body: some View {
        HStack(spacing: OOSpace.tiny) {
            Button {
                isExpanded.toggle()
            } label: {
                Text(isExpanded ? address : Self.short(address))
                    .font(OOFont.mono(size: 11, relativeTo: .caption2))
                    .foregroundStyle(OOColor.inkSecondary)
                    .lineLimit(isExpanded ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: ooMinimumTarget)
            }
            .accessibilityLabel(isExpanded ? address : "Agent address \(Self.short(address))")
            .accessibilityHint(isExpanded ? "Shows less" : "Shows the full address")

            Button(action: copy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    // O Chat's neutral-400 is 2.48:1, and a control's icon needs 3:1
                    .foregroundStyle(isCopied ? OOColor.primary : OOColor.inkSecondary)
                    .frame(width: ooMinimumTarget, height: ooMinimumTarget)
            }
            .accessibilityLabel(isCopied ? "Copied" : "Copy agent address")
        }
        .buttonStyle(.plain)
        .padding(.leading, OOSpace.medium)
        // the pill is drawn 28 points tall inside the 44 point targets
        .background {
            Capsule().fill(OOColor.paper)
                .overlay(Capsule().stroke(OOColor.hairline, lineWidth: 1))
                .padding(.vertical, 8)
        }
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = address
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #endif
        isCopied = true
        AccessibilityNotification.Announcement("Copied").post()
        // a second press restarts the 1.5 seconds, so the first can't clear the check mark early
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { isCopied = false }
        }
    }

    /// first ten and last six characters, as O Chat shows it
    static func short(_ address: String) -> String {
        address.count > 17 ? "\(address.prefix(10))…\(address.suffix(6))" : address
    }
}

#Preview("Address label") {
    OOPreviewPair {
        OOAddressLabel("0x3f9a0c51b2e94d7a8c6f1e0b9d2a4c7e5f8b1a3d6c9e2f4a7b0c3d5e8f1a2b4c")
    }
}
