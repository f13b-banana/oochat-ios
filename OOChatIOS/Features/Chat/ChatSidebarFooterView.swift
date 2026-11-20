import ConnectOnionKit
import SwiftUI

/// Settings, and Add agent as a small green button beside it: compact so it doesn't compete
/// with the chats, filled so it's easy to find. onPrimary on primary is above 6:1 (audit UI-008).
/// Rounded like every other shape in the drawer (the kit's 8 pt), not a pill.
struct ChatSidebarFooterView: View {
    let safeAreaInsets: EdgeInsets
    let onAddAgent: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
                    .font(.body)
                    .foregroundStyle(OOColor.ink)
                    .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
                    .frame(minHeight: OOSidebarMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarFooterButtonStyle())

            Spacer()

            Button(action: onAddAgent) {
                Label("Add agent", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OOColor.onPrimary)
                    .padding(.horizontal, OOSpace.medium)
                    .frame(height: 34)
                    .background(
                        OOColor.primary,
                        in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
                    )
                    // 44 pt to hit, the pill stays compact (story 162).
                    .frame(minHeight: OOSidebarMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarFooterButtonStyle())
        }
        .padding(.top, SidebarMetrics.footerTopPadding)
        .padding(.horizontal, SidebarMetrics.compactRowLeading)
        .padding(.bottom, safeAreaInsets.bottom + SidebarMetrics.footerBottomPadding)
        .background(alignment: .top) {
            OOColor.hairline.frame(height: 1)
        }
        .background(OOColor.surface)
    }
}
