import ConnectOnionKit
import SwiftUI
import UIKit

/// The empty-chat screen's pallette. Text, chips and lines come from
/// ConnectOnionKit's O Chat v12 tokens; the logo glow keeps its own values
/// until N2.3 restyles this screen
enum EmptyChatPalette {
    static let heading = OOColor.ink

    static let chipText = OOColor.ink

    static let chipIcon = OOColor.inkSecondary

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
    static let logoOuterAuraSize: CGFloat = 230
    static let logoOuterAuraStartRadius: CGFloat = 24
    static let logoOuterAuraEndRadius: CGFloat = 124
    static let logoOuterAuraBlur: CGFloat = 38
    static let logoAuraSize: CGFloat = 168
    static let logoAuraStartRadius: CGFloat = 12
    static let logoAuraEndRadius: CGFloat = 92
    static let logoAuraBlur: CGFloat = 28
    static let logoBacklightSize: CGFloat = 104
    static let logoBacklightStartRadius: CGFloat = 5
    static let logoBacklightEndRadius: CGFloat = 56
    static let logoBacklightBlur: CGFloat = 11
    static let logoIdleShadowRadius: CGFloat = 10
    static let logoActiveShadowRadius: CGFloat = 16
    static let logoIdleShadowOffset: CGFloat = 4
    static let logoActiveShadowOffset: CGFloat = 6
    static let logoPulseDuration: TimeInterval = 3.4
    static let headingMaximumWidth: CGFloat = 280
    static let suggestionGroupMaximumWidth: CGFloat = 344
    static let chipSpacing: CGFloat = 7
    static let chipContentSpacing: CGFloat = 6
    static let chipMinimumHeight: CGFloat = 36
    static let chipHorizontalPadding: CGFloat = 12
    static let chipIconSize: CGFloat = 15
    static let chipCornerRadius: CGFloat = 16
    static let chipShadowRadius: CGFloat = 8
    static let chipShadowOffset: CGFloat = 2

    static func logoImageOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.96 : 0.88
    }

    static func logoOuterAuraCoreOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.085 : 0.055
    }

    static func logoOuterAuraEdgeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.035 : 0.025
    }

    static func logoAuraCoreOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.17 : 0.13
    }

    static func logoAuraEdgeOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.065 : 0.055
    }

    static func logoShadowOpacity(isActive: Bool, colorScheme: ColorScheme) -> Double {
        if colorScheme == .dark {
            return isActive ? 0.20 : 0.13
        }

        return isActive ? 0.12 : 0.07
    }
}
