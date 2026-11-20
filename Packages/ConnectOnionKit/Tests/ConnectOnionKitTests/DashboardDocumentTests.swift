import XCTest
@testable import ConnectOnionKit

/// Guards the dashboard's sandbox boundary: the CSP and the bridge must survive
/// *any* agent-authored HTML, because that HTML is untrusted input.
///
/// The hostile cases are the regression suite for the injection approach this
/// replaced — locating `<head>` by matching the raw string, which a stray
/// `<head>` inside a comment defeated, moving the CSP meta into that comment and
/// dropping the policy entirely. Ported from oo-chat-web's
/// `build-srcdoc.test.ts` and Android's `DashboardDocumentTest.kt`; anything
/// asserting "the CSP is present and authoritative regardless of what the agent
/// wrote" belongs here.
final class DashboardDocumentTests: XCTestCase {

    private let nonce = "deadbeefdeadbeefdeadbeefdeadbeef"

    /// Everything before the agent's content — the part the agent must not be able to reach.
    private func ourHead(_ doc: String) -> String {
        guard let range = doc.range(of: "<body>") else {
            XCTFail("Document is missing <body>")
            return ""
        }

        return String(doc[..<range.lowerBound])
    }

    private let hostile: [(label: String, html: String)] = [
        (
            "a <head> inside a comment",
            "<!-- <head> --><html><head><title>T</title></head><body>hi</body></html>"
        ),
        (
            "a <head> in text content",
            "<html><body><p>put &lt;head&gt; here</p><head></head></body></html>"
        ),
        (
            "a </body> inside a comment",
            "<html><body><!-- </body> --><p>hi</p></body></html>"
        ),
        (
            "no head at all",
            "<html><body>hi</body></html>"
        ),
        (
            "no html or body",
            "<div>just a fragment</div>"
        ),
        (
            "its own CSP meta first",
            #"<html><head><meta http-equiv="Content-Security-Policy" content="default-src *"></head><body>hi</body></html>"#
        ),
        (
            "an unterminated attribute",
            #"<html><body><div title="oops"#
        ),
        (
            "an unterminated comment",
            "<html><body><p>hi</p><!-- never closed"
        ),
        (
            "an unterminated script tag",
            #"<html><body><script nonce=""#
        ),
        (
            "an empty document",
            ""
        )
    ]

    // The CSP is authoritative

    func testTheCSPStaysAheadOfTheAgentContentForEveryHostileDocument() {
        let meta = DashboardDocument.cspMeta(nonce: nonce)

        for (label, html) in hostile {
            let doc = DashboardDocument.buildSrcDoc(html: html, nonce: nonce)
            let head = ourHead(doc)

            // Present, in *our* head, before a single agent byte is parsed.
            XCTAssertTrue(head.contains(meta), label)

            if !html.isEmpty {
                let prefix = String(html.prefix(20))
                XCTAssertFalse(head.contains(prefix), label)
            }

            // Not commented out: no comment opens before the meta.
            if let metaRange = head.range(of: meta) {
                let beforeMeta = head[..<metaRange.lowerBound]
                XCTAssertFalse(beforeMeta.contains("<!--"), label)
            } else {
                XCTFail("Missing CSP meta for case: \(label)")
            }
        }
    }

    func testTheBridgeStaysAheadOfTheAgentContentForEveryHostileDocument() {
        let script = DashboardDocument.bridgeScript(nonce: nonce)

        for (label, html) in hostile {
            let doc = DashboardDocument.buildSrcDoc(html: html, nonce: nonce)
            let head = ourHead(doc)
            XCTAssertTrue(head.contains(script), label)
        }
    }

    func testTheAgentHTMLIsNeverRewritten() {
        let html = "<html><head><style>body{color:red}</style></head><body><h1>Hi</h1></body></html>"
        let doc = DashboardDocument.buildSrcDoc(html: html, nonce: nonce)
        XCTAssertTrue(doc.contains(html))
    }

    func testTheCSPLocksDownEveryFetchClassAnAgentCouldUseToPhoneHome() {
        let csp = DashboardDocument.cspMeta(nonce: nonce)
        XCTAssertTrue(csp.contains("default-src 'none'"))    // covers connect/frame/script fallbacks
        XCTAssertTrue(csp.contains("style-src 'unsafe-inline'"))
        XCTAssertTrue(csp.contains("img-src data:"))         // no remote pixels
        XCTAssertTrue(csp.contains("font-src data:"))
        XCTAssertTrue(csp.contains("script-src 'nonce-\(nonce)'"))

        // Agent inline scripts must not be admitted alongside the nonce.
        let unsafeInlineScriptPattern = #"script-src[^;"]*'unsafe-inline'"#
        XCTAssertNil(csp.range(of: unsafeInlineScriptPattern, options: .regularExpression))
    }

    func testOnlyTheNoncedBridgeScriptIsAdmitted() throws {
        let doc = DashboardDocument.buildSrcDoc(html: "<body><script>alert(1)</script></body>", nonce: nonce)
        let regex = try NSRegularExpression(pattern: "<script[^>]*>")
        let nsRange = NSRange(doc.startIndex..<doc.endIndex, in: doc)
        let matches = regex.matches(in: doc, range: nsRange)

        let tags: [String] = matches.compactMap { match in
            guard let range = Range(match.range, in: doc) else { return nil }
            return String(doc[range])
        }

        XCTAssertEqual(tags.count, 2) // ours + the agent's, which the CSP refuses to run
        XCTAssertEqual(tags.filter { $0.contains(#"nonce="\#(nonce)""#) }.count, 1)
    }

    func testTheAgentsOwnScriptTagCarriesNoNonce() {
        let doc = DashboardDocument.buildSrcDoc(html: #"<script src="x.js"></script>"#, nonce: nonce)
        guard let bodyOpen = doc.range(of: "<body>"),
              let bodyClose = doc.range(of: "</body>", range: bodyOpen.upperBound..<doc.endIndex) else {
            XCTFail("Missing <body>...</body>")
            return
        }
        let agentTag = String(doc[bodyOpen.upperBound..<bodyClose.lowerBound])
        XCTAssertTrue(agentTag.contains("<script"))
        XCTAssertFalse(agentTag.contains("nonce"))
    }

    // The wrapper document

    func testCharsetAndViewportAreOursSinceTheAgentsCopiesLandInBody() {
        let doc = DashboardDocument.buildSrcDoc(
            html: #"<html><head><meta charset="utf-16"></head><body>hi</body></html>"#,
            nonce: nonce
        )
        let head = ourHead(doc)
        XCTAssertTrue(head.contains(#"<meta charset="utf-8">"#))
        XCTAssertTrue(head.contains(#"name="viewport""#))
    }

    // The bridge

    func testTheBridgePostsTheSkillAndArgsFromTheClickedElementAndNothingElse() {
        let src = DashboardDocument.bridgeScript(nonce: nonce)
        XCTAssertTrue(src.contains("window.webkit.messageHandlers.\(DashboardDocument.defaultMessageHandlerName).postMessage"))
        XCTAssertTrue(src.contains("data-ochat-skill"))
        XCTAssertTrue(src.contains("data-ochat-args"))

        // One-way: it reads the frame's own DOM and calls out. It must never
        // accept messages back in or reach for anything outside the document.
        XCTAssertNil(src.range(of: #"addEventListener\(\s*'message'"#, options: .regularExpression))
        XCTAssertFalse(src.contains("parent."))
    }

    func testTheBridgeCancelsClicksOnExternalLinksButLeavesSamePageFragmentsAlone() {
        // Neither the CSP nor the opaque origin stops a page navigating itself,
        // so a link is the one way agent HTML could replace Home with a
        // document running under its own CSP.
        let src = DashboardDocument.bridgeScript(nonce: nonce)
        XCTAssertTrue(src.contains("closest('a[href]')"))
        XCTAssertTrue(src.contains("charAt(0) !== '#'"))
        XCTAssertTrue(src.contains("preventDefault"))
    }

    func testTheSkillBranchCancelsTheDefaultActionSoAnAnchorButtonCannotNavigate() {
        // Without this, <a href="..." data-ochat-skill="x"> would run the skill
        // *and* navigate away.
        let src = DashboardDocument.bridgeScript(nonce: nonce)
        guard let start = src.range(of: "data-ochat-skill")?.lowerBound,
              let end = src.range(of: "postMessage", range: start..<src.endIndex)?.lowerBound else {
            XCTFail("Expected skill branch and postMessage call in bridgeScript")
            return
        }
        let skillBranch = String(src[start..<end])
        XCTAssertTrue(skillBranch.contains("preventDefault"))
    }

    // The nonce

    func testGenerateNonceIs128BitsOfHex() {
        let generated = DashboardDocument.generateNonce()
        XCTAssertNotNil(generated.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
    }

    func testGenerateNonceIsFreshPerCallAReusedNonceWouldLetOneDashboardPredictTheNext() {
        let nonces = Set((1...100).map { _ in DashboardDocument.generateNonce() })
        XCTAssertEqual(nonces.count, 100)
    }
}
