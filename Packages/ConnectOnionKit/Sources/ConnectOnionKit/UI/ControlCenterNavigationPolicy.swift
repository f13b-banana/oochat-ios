import Foundation

// Pure navigation rule for the Control Center page, kept free of WebKit types so it can be unit tested.
//
// With `baseURL: nil`, `loadHTMLString` gives the document the URL `about:blank`.
// A `#fragment` link therefore navigates to `about:blank#fragment`.
//
// It takes the URL as a string on purpose: `about:` URLs have no authority or path hierarchy, and
// Foundation's URL parsers disagree about where the `#` fragment starts. Comparing the string
// does not depend on any of them.
//
// `isOwnLoad` is true only between our own `loadHTMLString` call and the policy decision it triggers.
enum ControlCenterNavigationPolicy {
    static let documentURL = "about:blank"

    static func allows(urlString: String?, isMainFrame: Bool, isOwnLoad: Bool) -> Bool {
        guard isMainFrame, let urlString else { return false }
        let base = urlString.firstIndex(of: "#").map { String(urlString[..<$0]) } ?? urlString
        guard base.lowercased() == documentURL else { return false }
        return hasFragment(urlString) || isOwnLoad
    }

    /// True for `about:blank#anything`, including a bare `#`.
    static func hasFragment(_ urlString: String) -> Bool {
        urlString.contains("#")
    }
}
