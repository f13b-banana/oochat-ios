#if canImport(SwiftUI) && canImport(WebKit)
import SwiftUI
import WebKit

// Renders the Agent Control Center document in a locked-down web view.
//
// - `html` is loaded with no base URL into a non-persistent data store. It reloads only when the string changes.
// - `onSkill` receives `(skill, args)` when the page posts to the bridge.
public struct ControlCenterWebView: View {
    private let html: String
    private let onSkill: ControlCenterSkillHandler

    public init(html: String, onSkill: @escaping ControlCenterSkillHandler = { _, _ in }) {
        self.html = html
        self.onSkill = onSkill
    }

    public var body: some View {
        ControlCenterWebRepresentable(html: html, onSkill: onSkill)
    }
}

/// Internal on purpose: keeps the coordinator and WebKit types out of the public API.
struct ControlCenterWebRepresentable {
    let html: String
    let onSkill: ControlCenterSkillHandler

    @MainActor func makeCoordinator() -> ControlCenterCoordinator {
        ControlCenterCoordinator(onSkill: onSkill)
    }
}

#if os(iOS)
extension ControlCenterWebRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(html: html, onSkill: onSkill)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: ControlCenterCoordinator) {
        coordinator.tearDown(webView)
    }
}
#elseif os(macOS)
extension ControlCenterWebRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(html: html, onSkill: onSkill)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: ControlCenterCoordinator) {
        coordinator.tearDown(webView)
    }
}
#endif
#endif
