import SwiftUI

enum ChatSidebarSelection: Equatable {
    case conversation(String)
}

// Sidebar metrics and constants.
enum SidebarMetrics {
    static let outerLeading: CGFloat = 22
    static let outerTrailing: CGFloat = 18
    static let rowLeading: CGFloat = 22
    static let compactRowLeading: CGFloat = 12
    static let compactRowTrailing: CGFloat = 10
    static let headerBottomPadding: CGFloat = 26
    static let headerSpacing: CGFloat = 12
    static let headerLogoSpacing: CGFloat = 12
    static let brandTopPadding: CGFloat = -3
    static let headerTrailingSpacing: CGFloat = 12
    static let headerIconButtonSize: CGFloat = 44
    static let searchButtonVerticalOffset: CGFloat = -8
    static let logoSize: CGFloat = 34
    static let statusSpacing: CGFloat = 10
    static let statusDotSize: CGFloat = 8
    static let activityIndicatorSlotSize: CGFloat = 18
    static let activityIndicatorStrokeWidth: CGFloat = 1.5
    static let searchFieldSpacing: CGFloat = 8
    static let searchFieldHorizontalPadding: CGFloat = 12
    static let searchFieldHeight: CGFloat = 42
    static let searchClearButtonSize: CGFloat = 24
    static let agentsHeaderTopPadding: CGFloat = 0
    static let agentsHeaderBottomPadding: CGFloat = 10
    static let sectionHeaderHorizontalPadding: CGFloat = 10
    static let minimumRowHeight: CGFloat = 0
    static let footerButtonHorizontalPadding: CGFloat = 18
    static let settingsButtonStrokeOpacity: Double = 0.20
    static let chevronWidth: CGFloat = 24
    static let agentRowSpacing: CGFloat = 8
    static let agentRowHeight: CGFloat = 34
    static let avatarSize: CGFloat = 32
    static let agentAvatarSpacing: CGFloat = 10
    static let agentNameSpacing: CGFloat = 8
    static let agentActionButtonSize: CGFloat = 34
    static let agentActionIconSize: CGFloat = 16
    static let sessionIndent: CGFloat = 36
    static let sessionIconWidth: CGFloat = 18
    static let sessionContentSpacing: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 10
    static let conversationTextLeading = rowLeading + rowHorizontalPadding + sessionIndent + sessionIconWidth + sessionContentSpacing

    static let primaryRowInsets = EdgeInsets(top: 2, leading: compactRowLeading, bottom: 2, trailing: compactRowTrailing)
    static let conversationRowInsets = EdgeInsets(top: 0, leading: compactRowLeading, bottom: 0, trailing: compactRowTrailing)
    /// An open agent lists this many chats, then "Show all (n)" (spec D2).
    static let chatsBeforeShowAll = 5
    static let emptySessionRowInsets = EdgeInsets(top: 6, leading: compactRowLeading + 24, bottom: 6, trailing: outerTrailing)
}
