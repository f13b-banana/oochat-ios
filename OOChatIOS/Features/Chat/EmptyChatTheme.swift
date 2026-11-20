import ConnectOnionKit
import SwiftUI
import UIKit

/// The empty-chat screen's pallette. Text, chips and lines come from
/// ConnectOnionKit's O Chat v12 tokens; the logo glow keeps its own values
/// until N2.3 restyles this screen
enum EmptyChatPalette {
    static let heading = OOColor.ink

    static let chipText = OOColor.ink

    // The same green command glyph the composer's / picker uses, so chips read as skills.
    static let chipIcon = AppTheme.primary

    static let chipFill = OOColor.paper

    static let chipStroke = OOColor.hairline

    static let chipPressedFill = OOColor.hover

    static let chipPressedStroke = OOColor.hairline

    static let chipShadow = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(white: 0, alpha: 0.28)
        } else {
            return UIColor(white: 0, alpha: 0.02)
        }
    })

    static let logoBacklightCore = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            // brand-100
            return UIColor(red: 220.0 / 255.0, green: 252.0 / 255.0, blue: 231.0 / 255.0, alpha: 0.14)
        } else {
            return UIColor(white: 1, alpha: 0)
        }
    })

    static let logoBacklightEdge = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 34.0 / 255.0, green: 197.0 / 255.0, blue: 94.0 / 255.0, alpha: 0.06)
        } else {
            return UIColor(white: 1, alpha: 0)
        }
    })

    static let logoShadow = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            // brand-300
            return UIColor(red: 134.0 / 255.0, green: 239.0 / 255.0, blue: 172.0 / 255.0, alpha: 1)
        } else {
            return UIColor(red: 22.0 / 255.0, green: 163.0 / 255.0, blue: 74.0 / 255.0, alpha: 1)
        }
    })
}

enum EmptyChatMetrics {
    static let sectionSpacing: CGFloat = 22
    static let headingSpacing: CGFloat = 6
    static let topOffset: CGFloat = 58
    static let verticalPadding: CGFloat = 36
    static let logoStageSize: CGFloat = 132
    static let logoSize: CGFloat = 72
    static let logoImageVerticalOffset: CGFloat = 1
    static let logoBacklightSize: CGFloat = 104
    static let logoBacklightStartRadius: CGFloat = 5
    static let logoBacklightEndRadius: CGFloat = 56
    static let logoBacklightBlur: CGFloat = 11
    static let logoShadowRadius: CGFloat = 10
    static let logoShadowOffset: CGFloat = 4
    static let headingMaximumWidth: CGFloat = 280
    static let suggestionGroupMaximumWidth: CGFloat = 344
    static let chipSpacing: CGFloat = 7
    static let chipContentSpacing: CGFloat = 7
    static let chipMinimumHeight: CGFloat = 44
    static let chipHorizontalPadding: CGFloat = 12
    static let chipIconSize: CGFloat = 15
    static let chipCornerRadius: CGFloat = 16
    static let chipShadowRadius: CGFloat = 8
    static let chipShadowOffset: CGFloat = 2

    static func logoImageOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.96 : 0.88
    }

    static func logoShadowOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.13 : 0.07
    }
}
