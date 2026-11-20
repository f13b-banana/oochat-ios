import Foundation
import XCTest
@testable import ConnectOnionKit

final class ControlCenterNavigationPolicyTests: XCTestCase {
    private func allows(_ string: String?, main: Bool = true, own: Bool = false) -> Bool {
        ControlCenterNavigationPolicy.allows(urlString: string, isMainFrame: main, isOwnLoad: own)
    }

    func testOwnLoadIsAllowedOnce() {
        XCTAssertTrue(allows("about:blank", own: true))
        XCTAssertFalse(allows("about:blank", own: false))
    }

    func testFragmentLinksAreAllowed() {
        XCTAssertTrue(allows("about:blank#section"))
        XCTAssertTrue(allows("about:blank#"))
    }

    func testEverythingElseIsCancelled() {
        for url in ["https://example.com", "http://example.com", "file:///etc/passwd",
                    "data:text/html,hi", "javascript:alert(1)", "blob:abc", "about:srcdoc", "about:blank/x#y"] {
            XCTAssertFalse(allows(url, own: true), url)
        }
        XCTAssertFalse(allows(nil, own: true))
    }

    func testSchemeAndHostCaseDoNotMatter() {
        XCTAssertTrue(allows("ABOUT:BLANK", own: true))
        XCTAssertTrue(allows("About:Blank#Top"))
    }

    func testFragmentDetection() {
        XCTAssertTrue(ControlCenterNavigationPolicy.hasFragment("about:blank#x"))
        XCTAssertTrue(ControlCenterNavigationPolicy.hasFragment("about:blank#"))
        XCTAssertFalse(ControlCenterNavigationPolicy.hasFragment("about:blank"))
    }

    func testSubframeAndNewWindowAreCancelled() {
        XCTAssertFalse(allows("about:blank", main: false, own: true))
        XCTAssertFalse(allows("about:blank#x", main: false))
    }
}

final class ControlCenterBridgeMessageTests: XCTestCase {
    func testParsesTheMessageTheDashboardScriptPosts() throws {
        let body: [String: Any] = ["type": "ochat:skill", "skill": "ping", "args": "hello world"]
        let parsed = try XCTUnwrap(ControlCenterBridgeMessage.parse(body))
        XCTAssertEqual(parsed.skill, "ping")
        XCTAssertEqual(parsed.args, "hello world")
    }

    func testEmptyArgsStayEmpty() throws {
        let parsed = try XCTUnwrap(ControlCenterBridgeMessage.parse(["skill": "ping", "args": ""]))
        XCTAssertEqual(parsed.args, "")
    }

    func testMissingOrNullArgsBecomeEmptyString() throws {
        XCTAssertEqual(try XCTUnwrap(ControlCenterBridgeMessage.parse(["skill": "s"])).args, "")
        XCTAssertEqual(try XCTUnwrap(ControlCenterBridgeMessage.parse(["skill": "s", "args": NSNull()])).args, "")
    }

    func testNonStringArgsAreDropped() {
        XCTAssertNil(ControlCenterBridgeMessage.parse(["skill": "s", "args": ["a": "b"]]))
        XCTAssertNil(ControlCenterBridgeMessage.parse(["skill": "s", "args": ["a", "b"]]))
        XCTAssertNil(ControlCenterBridgeMessage.parse(["skill": "s", "args": 5]))
    }

    func testMalformedMessagesAreDropped() {
        XCTAssertNil(ControlCenterBridgeMessage.parse("ping"))
        XCTAssertNil(ControlCenterBridgeMessage.parse(["args": "x"]))
        XCTAssertNil(ControlCenterBridgeMessage.parse(["skill": ""]))
        XCTAssertNil(ControlCenterBridgeMessage.parse(["skill": 5]))
    }
}

#if canImport(WebKit)
import WebKit

final class ControlCenterContentRulesTests: XCTestCase {
    func testRuleJSONBlocksEverySchemeExceptData() throws {
        let data = Data(ControlCenterContentRules.encodedRules.utf8)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let filters = rules.compactMap { ($0["trigger"] as? [String: String])?["url-filter"] }
        XCTAssertEqual(filters, ["^http:", "^https:", "^ws:", "^wss:", "^ftp:", "^file:", "^blob:"])
        XCTAssertFalse(filters.contains { $0.contains("data") })
        XCTAssertTrue(rules.allSatisfy { ($0["action"] as? [String: String])?["type"] == "block" })
    }

    /// The one test that proves WebKit accepts the filter syntax. If it cannot run under
    /// `swift test`, run it through xcodebuild.
    @MainActor
    func testRulesCompileInWebKit() async throws {
        _ = try await ControlCenterContentRules.compiledList()
    }
}

final class ControlCenterDocumentTests: XCTestCase {
    /// The page posts to the handler the web view registers. If these ever drift, every button is dropped.
    @MainActor
    func testRegisteredHandlerNameIsTheOneThePageScriptPostsTo() async {
        let name = ControlCenterCoordinator.messageHandlerName
        XCTAssertEqual(name, DashboardDocument.defaultMessageHandlerName)
        let document = ControlCenterCoordinator.wrapInDashboardDocument(html: "<p>hi</p>", messageHandlerName: name)
        XCTAssertTrue(document.contains("window.webkit.messageHandlers.\(name).postMessage"))
    }

    func testDefaultBuilderWrapsTheAgentHTML() {
        let document = ControlCenterCoordinator.wrapInDashboardDocument(html: "<p>hi</p>", messageHandlerName: "ochat")
        XCTAssertTrue(document.contains("<p>hi</p>"))
        XCTAssertTrue(document.contains("Content-Security-Policy"))
        XCTAssertTrue(document.contains("default-src 'none'"))
    }

    func testEachBuildGetsAFreshNonce() {
        let first = ControlCenterCoordinator.wrapInDashboardDocument(html: "x", messageHandlerName: "ochat")
        let second = ControlCenterCoordinator.wrapInDashboardDocument(html: "x", messageHandlerName: "ochat")
        XCTAssertNotEqual(first, second)
    }
}

// WKFrameInfo, WKNavigationAction and WKScriptMessage cannot be built directly, so the tests subclass them.
private final class FakeFrame: WKFrameInfo {
    private let main: Bool
    init(main: Bool) {
        self.main = main
        super.init()
    }
    override var isMainFrame: Bool { main }
}

private final class FakeNavigationAction: WKNavigationAction {
    private let url: String
    private let main: Bool
    init(_ url: String, main: Bool = true) {
        self.url = url
        self.main = main
        super.init()
    }
    override var request: URLRequest {
        URLRequest(url: URL(string: url) ?? URL(fileURLWithPath: "/"))
    }
    override var targetFrame: WKFrameInfo? { FakeFrame(main: main) }
}

private final class FakeMessage: WKScriptMessage {
    private let payload: Any
    private let main: Bool
    init(_ payload: Any, main: Bool = true) {
        self.payload = payload
        self.main = main
        super.init()
    }
    override var name: String { ControlCenterCoordinator.messageHandlerName }
    override var body: Any { payload }
    override var frameInfo: WKFrameInfo { FakeFrame(main: main) }
}

final class ControlCenterCoordinatorTests: XCTestCase {
    /// Story 22 AC4: a SwiftUI redraw with the same html must not rebuild (new nonce) or reload the page.
    /// A crash reloads the last html, built again so it gets a fresh nonce.
    @MainActor
    func testDocumentIsBuiltOncePerDistinctHTMLAndRebuiltAfterACrash() async throws {
        var built: [String] = []
        let steps = [expectation(description: "first"), expectation(description: "second"), expectation(description: "third")]
        let coordinator = ControlCenterCoordinator(onSkill: { _, _ in }, documentBuilder: { html, name in
            XCTAssertEqual(name, DashboardDocument.defaultMessageHandlerName)
            built.append(html)
            if built.count <= steps.count { steps[built.count - 1].fulfill() }
            return "<html>\(html)</html>"
        })
        let webView = coordinator.makeWebView()

        coordinator.update(html: "a", onSkill: { _, _ in })
        await fulfillment(of: [steps[0]], timeout: 15)
        coordinator.update(html: "a", onSkill: { _, _ in })
        coordinator.update(html: "a", onSkill: { _, _ in })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(built, ["a"])

        coordinator.update(html: "b", onSkill: { _, _ in })
        await fulfillment(of: [steps[1]], timeout: 15)
        XCTAssertEqual(built, ["a", "b"])

        coordinator.webViewWebContentProcessDidTerminate(webView)
        await fulfillment(of: [steps[2]], timeout: 15)
        XCTAssertEqual(built, ["a", "b", "b"])

        coordinator.tearDown(webView)
    }
}
#endif
