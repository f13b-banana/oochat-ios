import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// O Chat v12 design tokens, from oo-chat main at 8a5f5a8 (app/globals.css and the
/// role table in docs/DESIGN_SYSTEM.md). Amber and red are Tailwind 4.3.3's defaults,
/// which oo-chat does not set itself; their dark values follow the color-mix rules
/// in app/globals.css, converted to sRGB.

/// One colour role as sRGB hex for light and dark. The contrast test reads these.
struct OOHexPair: Sendable {
    let light: UInt32
    let dark: UInt32
}

/// The raw values behind `OOColor`.
enum OOHex {
    static let paper = OOHexPair(light: 0xFFFFFF, dark: 0x111813)
    static let surface = OOHexPair(light: 0xF8FAF9, dark: 0x0B100D)
    static let hover = OOHexPair(light: 0xF1F5F2, dark: 0x17201A)
    static let hairline = OOHexPair(light: 0xE3E9E5, dark: 0x1F2A23)
    static let ink = OOHexPair(light: 0x122019, dark: 0xE9F0EB)
    static let inkSecondary = OOHexPair(light: 0x4F5F56, dark: 0xA4B3AA)
    static let inkTertiary = OOHexPair(light: 0x9AA8A0, dark: 0x67766D)
    static let selectedRule = OOHexPair(light: 0x25332B, dark: 0xD8E2DC)
    static let primary = OOHexPair(light: 0x146C43, dark: 0x3FBF7F)
    static let primaryHover = OOHexPair(light: 0x0F5A37, dark: 0x5BCF93)
    static let onPrimary = OOHexPair(light: 0xFFFFFF, dark: 0x06150D)
    static let currentTint = OOHexPair(light: 0xE9F4EE, dark: 0x16281E)
    static let tintText = OOHexPair(light: 0x146C43, dark: 0x7FD6A8)
    static let live = OOHexPair(light: 0x1F9D5C, dark: 0x3FBF7F)
    static let decisionFill = OOHexPair(light: 0xFFFBEB, dark: 0x292617)
    static let decisionLine = OOHexPair(light: 0xFEE685, dark: 0x553F18)
    static let decisionMark = OOHexPair(light: 0xE17100, dark: 0xE17100)
    static let decisionText = OOHexPair(light: 0x7B3306, dark: 0xFFDBAF)
    static let failureFill = OOHexPair(light: 0xFEF2F2, dark: 0x2B1F18)
    static let failureLine = OOHexPair(light: 0xFFC9C9, dark: 0x572920)
    static let failureMark = OOHexPair(light: 0xE7000B, dark: 0xE7000B)
    static let failureText = OOHexPair(light: 0xC10007, dark: 0xFF887F)
    static let claudeCodeTint = OOHexPair(light: 0xF8ECE6, dark: 0x2C1D17)
    static let claudeCodeTintText = OOHexPair(light: 0x9A4528, dark: 0xF2B39A)
    static let codexTint = OOHexPair(light: 0xEDF0FA, dark: 0x1A1F2E)
    static let codexTintText = OOHexPair(light: 0x3B4FA3, dark: 0xAEBCF2)
}

/// Colour roles.
/// called color and not colour as the other swift functions use color
public enum OOColor {
    /// white: page, cards and composer background
    public static let paper = dynamic(OOHex.paper)

    /// neutral-50: page ground, sidebar and Control Center pane background
    public static let surface = dynamic(OOHex.surface)

    /// neutral-100: hover and pressed rows, the user's message
    public static let hover = dynamic(OOHex.hover)

    /// neutral-200: one-point dividers and borders
    public static let hairline = dynamic(OOHex.hairline)

    /// neutral-900: body text
    public static let ink = dynamic(OOHex.ink)

    /// neutral-600: secondary text
    public static let inkSecondary = dynamic(OOHex.inkSecondary)

    /// neutral-400: placeholders and disabled text only (2.48:1 on paper)
    public static let inkTertiary = dynamic(OOHex.inkTertiary)

    /// neutral-800: the selected tab's underline
    public static let selectedRule = dynamic(OOHex.selectedRule)

    /// primary: the one primary action's fill, focus rings, the logo
    public static let primary = dynamic(OOHex.primary)

    /// primary-hover: the primary action while pressed or hovered
    public static let primaryHover = dynamic(OOHex.primaryHover)

    /// on-primary: text and icons on the primary fill
    public static let onPrimary = dynamic(OOHex.onPrimary)

    /// tint: the current item's background and the avatar tile
    public static let currentTint = dynamic(OOHex.currentTint)

    /// tint-fg: text on the current-item tint, the avatar initial and links
    public static let tintText = dynamic(OOHex.tintText)

    /// brand-500: the live dot only
    public static let live = dynamic(OOHex.live)

    /// amber-50, amber-200, amber-600 and amber-900: a decision waiting for the user
    public static let decisionFill = dynamic(OOHex.decisionFill)
    public static let decisionLine = dynamic(OOHex.decisionLine)
    public static let decisionMark = dynamic(OOHex.decisionMark)
    public static let decisionText = dynamic(OOHex.decisionText)

    /// red-50, red-200, red-600 and red-700: a failure or a destructive action
    public static let failureFill = dynamic(OOHex.failureFill)
    public static let failureLine = dynamic(OOHex.failureLine)
    public static let failureMark = dynamic(OOHex.failureMark)
    public static let failureText = dynamic(OOHex.failureText)

    /// warm clay: the Claude Code Provider on Work Room Cards and the Claude Station row.
    /// Not amber, which stays reserved for decisions.
    public static let claudeCodeTint = dynamic(OOHex.claudeCodeTint)
    public static let claudeCodeTintText = dynamic(OOHex.claudeCodeTintText)

    /// slate blue: the Codex Provider on Work Room Cards
    public static let codexTint = dynamic(OOHex.codexTint)
    public static let codexTintText = dynamic(OOHex.codexTintText)

    static func dynamic(_ pair: OOHexPair) -> Color {
        dynamic(light: pair.light, dark: pair.dark)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {

        #if canImport(UIKit)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })

        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
        #endif
    }
}

/// Spacing steps, in points.
public enum OOSpace {
    public static let tiny: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
}

/// Corner radii, in points: 2 to 8, and 10 for cards and the composer.
public enum OORadius {
    public static let tiny: CGFloat = 2
    public static let small: CGFloat = 4
    public static let medium: CGFloat = 6
    public static let large: CGFloat = 8
    public static let card: CGFloat = 10
}

/// Icon sizes, in points.
public enum OOIconSize {
    public static let small: CGFloat = 16
    public static let medium: CGFloat = 20
    public static let large: CGFloat = 24
}

/// The smallest tap target, in points.
public let ooMinimumTarget: CGFloat = 44

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
