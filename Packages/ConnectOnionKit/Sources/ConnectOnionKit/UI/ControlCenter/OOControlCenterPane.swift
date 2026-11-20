// webkit guard in the package itself as webkit is needed to view it
#if canImport(WebKit)
import SwiftUI

/// the Control Center pane itself

public struct OOControlCenterPane: View {
    private let dashboard: OIPDashboard
    private let skills: [OIPAgentSkill]?
    private let onRunSkill: @MainActor (String) -> Void
    private let onCollapse: (() -> Void)?
    @State private var refusalNotice: String?

    /// `skills` is the agent's list
    /// `onRunSkill` gets a checked `/skill args` line to send as a normal, visible chat message.
    /// Pass `onCollapse` when the pane sits beside the chat (Mac, iPad)
    public init(
        dashboard: OIPDashboard,
        skills: [OIPAgentSkill]? = nil,
        onRunSkill: @escaping @MainActor (String) -> Void = { _ in },
        onCollapse: (() -> Void)? = nil
    ) {
        self.dashboard = dashboard
        self.skills = skills
        self.onRunSkill = onRunSkill
        self.onCollapse = onCollapse
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let onCollapse {
                header(onCollapse: onCollapse)
            }
            content
                .overlay(alignment: .top) {
                    if let refusalNotice {
                        OOPaneNotice(message: refusalNotice) {
                            self.refusalNotice = nil
                        }
                    }
                }
        }
        .background(OOColor.surface)
    }

    /// The refusal notice overlays the page only,
    /// so it never covers the header's collapse button.
    @ViewBuilder
    private var content: some View {
        switch dashboard {
        case .page(let html):
            ControlCenterWebView(html: html) { [skills, onRunSkill] skill, args in
                refusalNotice = nil
                Self.runSkill(
                    skill,
                    args: args,
                    skills: skills,
                    onRunSkill: onRunSkill,
                    onRefused: { refusalNotice = $0 }
                )
            }
        case .tooLarge(let bytes):
            tooLargeNotice(bytes: bytes)
        }
    }

    /// A press is untrusted from the agent's HTML, so it is checked here, outside the web
    /// view, by SkillActionChecker.
    /// A refused press sends nothing and hands its short notice msg to `onRefused`.
    @MainActor
    static func runSkill(
        _ skill: String,
        args: String,
        skills: [OIPAgentSkill]?,
        onRunSkill: @MainActor (String) -> Void,
        onRefused: @MainActor (String) -> Void = { _ in }
    ) {
        switch SkillActionChecker.check(skill: skill, args: args, availableSkills: skills) {
        case .send(let message):
            onRunSkill(message)
        case .refused(let refusal):
            onRefused(refusal.message)
        }
    }

    static let title = "Control Center"
    static let collapseLabel = "Collapse Control Center"

    /// After the pane header in oo-chat components/dashboard/workspace-shell.tsx.
    private func header(onCollapse: @escaping () -> Void) -> some View {
        HStack {
            Text(Self.title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(OOColor.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onCollapse) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OOColor.inkSecondary)
                    .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.collapseLabel)
            .help(Self.collapseLabel)
        }
        .padding(.leading, OOSpace.large)
        .background(OOColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OOColor.hairline)
                .frame(height: 1)
        }
    }

    private func tooLargeNotice(bytes: Int) -> some View {
        VStack(spacing: OOSpace.small) {
            Image(systemName: "square.grid.2x2")
                .font(.title2)
                .foregroundStyle(OOColor.inkTertiary)
            Text("Control Center too large")
                .font(.headline)
                .foregroundStyle(OOColor.ink)
            Text(Self.tooLargeDetail(bytes: bytes))
                .font(.footnote)
                .foregroundStyle(OOColor.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(OOSpace.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OOColor.surface)
        .accessibilityElement(children: .combine)
    }

    static func tooLargeDetail(bytes: Int) -> String {
        "This page is \(size(bytes)); the app shows pages up to \(size(OIPDashboard.clientCapBytes))."
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

#Preview("Control Center pane") {
    VStack(spacing: 0) {
        OOControlCenterPane(dashboard: .page(html: "<h1>Hi</h1>"))
        OOControlCenterPane(dashboard: .tooLarge(bytes: 20 * 1024 * 1024))
    }
}
#endif
