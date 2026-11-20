import CoreText
import XCTest
@testable import ConnectOnionKit

/// Story N2 AC5: every text and background pair meets WCAG 2.2 AA, in light and dark.
final class OOTokensTests: XCTestCase {

    private struct Pair {
        let name: String
        let fore: OOHexPair
        let ground: OOHexPair

        init(_ name: String, _ fore: OOHexPair, _ ground: OOHexPair) {
            self.name = name
            self.fore = fore
            self.ground = ground
        }
    }

    /// Text pairs need 4.5:1.
    private let textPairs: [Pair] = [
        Pair("ink on paper", OOHex.ink, OOHex.paper),
        Pair("ink on surface", OOHex.ink, OOHex.surface),
        Pair("ink on hover", OOHex.ink, OOHex.hover),
        Pair("secondary on paper", OOHex.inkSecondary, OOHex.paper),
        Pair("secondary on surface", OOHex.inkSecondary, OOHex.surface),
        Pair("secondary on hover", OOHex.inkSecondary, OOHex.hover),
        Pair("on-primary on primary", OOHex.onPrimary, OOHex.primary),
        Pair("on-primary on primary hover", OOHex.onPrimary, OOHex.primaryHover),
        Pair("tint text on tint", OOHex.tintText, OOHex.currentTint),
        Pair("tint text on paper", OOHex.tintText, OOHex.paper),
        Pair("decision text on decision fill", OOHex.decisionText, OOHex.decisionFill),
        Pair("failure text on failure fill", OOHex.failureText, OOHex.failureFill),
        Pair("failure text on paper", OOHex.failureText, OOHex.paper),
        // N2.2 notices and the destructive button
        Pair("ink on decision fill", OOHex.ink, OOHex.decisionFill),
        Pair("secondary on decision fill", OOHex.inkSecondary, OOHex.decisionFill),
        Pair("secondary on failure fill", OOHex.inkSecondary, OOHex.failureFill),
        Pair("white on failure mark", OOHexPair(light: 0xFFFFFF, dark: 0xFFFFFF), OOHex.failureMark),
        // Provider tints on Work Room Cards
        Pair("Claude Code text on its tint", OOHex.claudeCodeTintText, OOHex.claudeCodeTint),
        Pair("Claude Code text on paper", OOHex.claudeCodeTintText, OOHex.paper),
        Pair("Codex text on its tint", OOHex.codexTintText, OOHex.codexTint),
        Pair("Codex text on paper", OOHex.codexTintText, OOHex.paper)
    ]

    /// Controls, focus rings and status marks need 3:1.
    private let markPairs: [Pair] = [
        Pair("primary on paper", OOHex.primary, OOHex.paper),
        Pair("primary on surface", OOHex.primary, OOHex.surface),
        Pair("live dot on paper", OOHex.live, OOHex.paper),
        Pair("live dot on surface", OOHex.live, OOHex.surface),
        Pair("decision mark on paper", OOHex.decisionMark, OOHex.paper),
        Pair("decision mark on decision fill", OOHex.decisionMark, OOHex.decisionFill),
        Pair("failure mark on paper", OOHex.failureMark, OOHex.paper),
        Pair("failure mark on failure fill", OOHex.failureMark, OOHex.failureFill)
    ]

    func testTextPairsMeetAA() {
        for pair in textPairs {
            assertContrast(pair, atLeast: 4.5)
        }
    }

    func testMarkPairsMeetNonTextAA() {
        for pair in markPairs {
            assertContrast(pair, atLeast: 3)
        }
    }

    /// Tertiary is below 4.5:1 by O Chat's design, so it is kept for placeholders
    /// and disabled text, which WCAG exempts. Fail if it drifts lower still.
    func testTertiaryStaysAtOChatsValue() {
        XCTAssertEqual(Self.ratio(OOHex.inkTertiary.light, OOHex.paper.light), 2.48, accuracy: 0.01)
        XCTAssertEqual(Self.ratio(OOHex.inkTertiary.dark, OOHex.paper.dark), 3.77, accuracy: 0.01)
    }

    func testRatioMatchesTheWCAGExtremes() {
        XCTAssertEqual(Self.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.001)
        XCTAssertEqual(Self.ratio(0x777777, 0x777777), 1, accuracy: 0.001)
    }

    func testEveryBundledFontRegistersAndResolves() {
        XCTAssertEqual(OOFonts.register(), [], "fonts missing from Resources/Fonts or failing to register")
        XCTAssertEqual(OOFonts.register(), [], "a second call must also succeed")
        for name in [OOFont.headlineName, OOFont.monoName, OOFont.monoMediumName] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, name)
        }
    }

    func testLogoIsBundled() {
        XCTAssertNotNil(OOLogo.url, "onion-green.png is missing from Resources")
    }

    private func assertContrast(_ pair: Pair, atLeast minimum: Double) {
        let light = Self.ratio(pair.fore.light, pair.ground.light)
        let dark = Self.ratio(pair.fore.dark, pair.ground.dark)
        XCTAssertGreaterThanOrEqual(light, minimum, "\(pair.name), light: \(light)")
        XCTAssertGreaterThanOrEqual(dark, minimum, "\(pair.name), dark: \(dark)")
    }

    /// WCAG 2.2 contrast ratio of two sRGB colours.
    static func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
