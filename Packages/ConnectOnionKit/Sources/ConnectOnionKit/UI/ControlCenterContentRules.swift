#if canImport(WebKit)
import Foundation
import WebKit

// The content rule list that keeps the Control Center page off the network.
// One rule per scheme, each a block on `^scheme:`. WebKit's url-filter dialect is a
// restricted regex (no alternation, no groups), so `^(https?|wss?)` is not used.
// `data:` is deliberately absent: the page may use data URIs for inline images and fonts.
enum ControlCenterContentRules {
    static let identifier = "ai.openonion.control-center.block-network"

    static let blockedSchemes = ["http", "https", "ws", "wss", "ftp", "file", "blob"]

    static let encodedRules: String = {
        let entries = blockedSchemes.map {
            #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"block"}}"#
        }
        return "[" + entries.joined(separator: ",") + "]"
    }()

    enum CompileError: Error {
        case storeUnavailable
    }

    @MainActor private static var cached: WKContentRuleList?

    /// Compiles the rules once per process and returns the cached list afterwards.
    @MainActor
    static func compiledList() async throws -> WKContentRuleList {
        if let cached { return cached }
        let store: WKContentRuleListStore? = WKContentRuleListStore.default()
        guard let store else { throw CompileError.storeUnavailable }
        let list = try await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: encodedRules
        )
        guard let list else { throw CompileError.storeUnavailable }
        cached = list
        return list
    }
}
#endif
