import CoreText
import SwiftUI

/// Type roles. System sans for everything, Fraunces for the one headline per
/// screen, JetBrains Mono for addresses and code. Both custom faces scale with
/// Dynamic Type through `relativeTo`.
public enum OOFont {
    /// PostScript names of the bundled faces.
    static let headlineName = "Fraunces72pt-SemiBold"
    static let monoName = "JetBrainsMono-Regular"
    static let monoMediumName = "JetBrainsMono-Medium"

    /// The one Fraunces line on a screen: the home headline or the agent's name.
    public static func headline(size: CGFloat = 28, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(headlineName, size: size, relativeTo: style)
    }

    /// Addresses, codes and tool output.
    public static func mono(size: CGFloat = 13, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(monoName, size: size, relativeTo: style)
    }

    /// Mono at medium weight, for a balance or a short code that needs emphasis.
    public static func monoMedium(size: CGFloat = 13, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(monoMediumName, size: size, relativeTo: style)
    }
}

/// Registers the package's fonts for this process. Call once at launch, before
/// the first view uses `OOFont`.
public enum OOFonts {
    /// Font files in Resources/Fonts.
    static let files = [
        "Fraunces72pt-SemiBold",
        "JetBrainsMono-Regular",
        "JetBrainsMono-Medium"
    ]

    /// Safe to call more than once. A face the app already registered itself
    /// (the macOS app lists JetBrains Mono in ATSApplicationFontsPath) counts as
    /// registered.
    @discardableResult
    public static func register() -> [String] {
        var missing: [String] = []
        for name in files {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else {
                missing.append(name)
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let code = error?.takeRetainedValue(),
               ![CTFontManagerError.alreadyRegistered, .duplicatedName].map(\.rawValue).contains(CFErrorGetCode(code)) {
                missing.append(name)
            }
        }
        return missing
    }
}
