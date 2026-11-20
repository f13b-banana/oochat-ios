#if canImport(WebKit)
import Foundation
import os
import WebKit

/// Called on the main actor with the skill name and the raw `data-ochat-args` string the page asked for.
/// The pane passes both straight to `SkillActionChecker.check(skill:args:availableSkills:)`.
public typealias ControlCenterSkillHandler = @MainActor (_ skill: String, _ args: String) -> Void

/// The single coordinator behind both the iOS and macOS representables.
/// It owns the web view's configuration, the navigation delegate, the bridge and the reload rules.
@MainActor
final class ControlCenterCoordinator: NSObject {
    /// Builds the document that is actually loaded from the agent's html.
    typealias DocumentBuilder = (_ html: String, _ messageHandlerName: String) -> String

    /// One name for both sides: the page's bridge script posts to it and the web view registers it.
    static let messageHandlerName = DashboardDocument.defaultMessageHandlerName
    static let accessibilityLabel = "Agent Control Center"

    private static let log = Logger(subsystem: "ai.openonion.ConnectOnionKit", category: "ControlCenterWebView")

    private enum RulesState { case notStarted, installing, installed, failed }

    private var onSkill: ControlCenterSkillHandler
    private let buildDocument: DocumentBuilder
    private weak var webView: WKWebView?
    private var rulesState = RulesState.notStarted
    private var rulesTask: Task<Void, Never>?
    private var requestedHTML: String?
    private var loadedHTML: String?
    private var ownLoadPending = false

    init(
        onSkill: @escaping ControlCenterSkillHandler,
        documentBuilder: @escaping DocumentBuilder = ControlCenterCoordinator.wrapInDashboardDocument
    ) {
        self.onSkill = onSkill
        self.buildDocument = documentBuilder
    }

    /// Default builder: the N1.2 wrapper (CSP, per-load nonce, bridge script, co-filter, co-table).
    /// Colours and font scale use the defaults until N2.1 supplies tokens.
    nonisolated static func wrapInDashboardDocument(html: String, messageHandlerName: String) -> String {
        DashboardDocument.buildSrcDoc(html: html, messageHandlerName: messageHandlerName)
    }

    // MARK: Web view

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            WeakScriptMessageHandler(target: self),
            name: Self.messageHandlerName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        // No uiDelegate on purpose: window.open, alert and friends have nothing to call.
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .clear

        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.accessibilityLabel = Self.accessibilityLabel
        #elseif os(macOS)
        // Undocumented key, but the only way to stop the white flash on macOS. Review point.
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(Self.accessibilityLabel)
        #endif

        #if DEBUG
        webView.isInspectable = true
        #endif

        self.webView = webView
        return webView
    }

    /// Called from `updateUIView` / `updateNSView`, which SwiftUI runs on every parent re-render.
    func update(html: String, onSkill: @escaping ControlCenterSkillHandler) {
        self.onSkill = onSkill
        requestedHTML = html
        switch rulesState {
        case .notStarted: installRules()
        case .installing, .failed: break
        case .installed: loadIfNeeded()
        }
    }

    func tearDown(_ webView: WKWebView) {
        rulesTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName)
        controller.removeAllContentRuleLists()
        self.webView = nil
    }

    // MARK: Loading

    /// The page must never load before the rules are in place. If compiling fails we stay blank.
    private func installRules() {
        rulesState = .installing
        rulesTask = Task { [weak self] in
            do {
                let list = try await ControlCenterContentRules.compiledList()
                guard let self, !Task.isCancelled, let webView = self.webView else { return }
                webView.configuration.userContentController.add(list)
                self.rulesState = .installed
                self.loadIfNeeded()
            } catch {
                self?.rulesState = .failed
                Self.log.error("Content rule list failed to compile; page not loaded: \(error.localizedDescription)")
            }
        }
    }

    private func loadIfNeeded() {
        guard let webView, let html = requestedHTML, html != loadedHTML else { return }
        load(html, in: webView)
    }

    /// The only place a document is built. `loadedHTML` stays the raw agent html, so "reload only when the
    /// html changes" still compares what the agent sent. The nonce is fresh on every load, including the
    /// reload after a web content crash, and never changes on a plain SwiftUI redraw.
    private func load(_ html: String, in webView: WKWebView) {
        loadedHTML = html
        ownLoadPending = true
        let document = buildDocument(html, Self.messageHandlerName)
        webView.loadHTMLString(document, baseURL: nil)
    }

    // MARK: Bridge

    func handle(_ message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName, message.frameInfo.isMainFrame else { return }
        guard let parsed = ControlCenterBridgeMessage.parse(message.body) else {
            Self.log.debug("Dropped a malformed bridge message")
            return
        }
        onSkill(parsed.skill, parsed.args)
    }
}

extension ControlCenterCoordinator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let urlString = navigationAction.request.url?.absoluteString
        let allowed = ControlCenterNavigationPolicy.allows(
            urlString: urlString,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
            isOwnLoad: ownLoadPending
        )
        if allowed, let urlString, !ControlCenterNavigationPolicy.hasFragment(urlString) { ownLoadPending = false }
        return allowed ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let html = loadedHTML else { return }
        Self.log.notice("Web content process terminated; reloading last document")
        load(html, in: webView)
    }
}

/// WKUserContentController retains its handlers strongly. This proxy holds the coordinator weakly,
/// so the coordinator can still be released when SwiftUI drops the view.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: ControlCenterCoordinator?

    init(target: ControlCenterCoordinator) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message)
    }
}
#endif
