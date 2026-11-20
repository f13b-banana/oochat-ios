import ConnectOnionKit
import SwiftUI

struct ChatSidebarHeaderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onlineAgentCount: Int
    let isSearchVisible: Bool
    @Binding var searchText: String
    let searchFieldFocus: FocusState<Bool>.Binding
    let onToggleSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarMetrics.headerSpacing) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: SidebarMetrics.headerSpacing) {
                    brandTitle
                    connectionStatus
                }
                .padding(.top, SidebarMetrics.brandTopPadding)
                .padding(.trailing, SidebarMetrics.headerIconButtonSize + SidebarMetrics.headerTrailingSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)

                searchToggleButton
                    .offset(y: SidebarMetrics.searchButtonVerticalOffset)
            }

            if isSearchVisible {
                SidebarSearchField(text: $searchText, focus: searchFieldFocus)
                    .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
            }
        }
    }

    private var brandTitle: some View {
        HStack(spacing: SidebarMetrics.headerLogoSpacing) {
            OOLogo.image
                .resizable()
                .scaledToFit()
                .frame(width: SidebarMetrics.logoSize, height: SidebarMetrics.logoSize)

            Text("oo-chat")
                .font(.title3.bold())
                .lineLimit(1)
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: SidebarMetrics.statusSpacing) {
            Circle()
                .fill(onlineAgentCount > 0 ? Color(.systemGreen) : Color(.tertiaryLabel))
                .frame(width: SidebarMetrics.statusDotSize, height: SidebarMetrics.statusDotSize)

            Text(connectionSummary)
                .font(.footnote)
                .foregroundStyle(OOColor.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var searchToggleButton: some View {
        Button {
            onToggleSearch()
        } label: {
            SidebarIconButtonLabel(
                systemName: isSearchVisible ? "xmark" : "magnifyingglass",
                foregroundColor: AppTheme.primary,
                size: SidebarMetrics.headerIconButtonSize,
                font: .system(size: 16, weight: .semibold)
            )
        }
        .buttonStyle(SidebarFooterButtonStyle())
        .accessibilityLabel(isSearchVisible ? "Close search" : "Search")
    }

    private var connectionSummary: String {
        let noun = onlineAgentCount == 1 ? "agent" : "agents"
        return "\(onlineAgentCount) \(noun) online"
    }
}

struct SidebarSearchField: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: SidebarMetrics.searchFieldSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))

            TextField("Search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focus)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: SidebarMetrics.searchClearButtonSize, height: SidebarMetrics.searchClearButtonSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, SidebarMetrics.searchFieldHorizontalPadding)
        .frame(height: SidebarMetrics.searchFieldHeight)
        .background(Color(.secondarySystemFill), in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

struct SidebarIconButtonLabel: View {
    let systemName: String
    let foregroundColor: Color
    let size: CGFloat
    let font: Font

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .foregroundStyle(foregroundColor)
            .frame(width: size, height: size)
            .glassBackground(
                in: Circle(),
                interactive: true,
                tint: Color(.systemBackground),
                fallback: Color(.tertiarySystemFill)
            )
            .overlay {
                Circle()
                    .stroke(Color(.separator).opacity(SidebarMetrics.settingsButtonStrokeOpacity), lineWidth: 0.5)
            }
    }
}
