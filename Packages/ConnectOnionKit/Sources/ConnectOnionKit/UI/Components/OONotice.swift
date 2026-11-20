import SwiftUI

/// amber when the reader has to decide, red when something failed
/// from oo-chat components/chat/chat-approval.tsx and components/agent-address.tsx
public struct OONotice<Actions: View>: View {
    public enum Kind: Sendable {
        case decision
        case failure
    }

    private let kind: Kind
    private let title: String
    private let message: String?
    private let actions: Actions

    public init(_ kind: Kind, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
        VStack(alignment: .leading, spacing: OOSpace.small) {
            HStack(spacing: OOSpace.small) {
                Circle().fill(mark).frame(width: 8, height: 8)
                Text(Self.heading(kind).uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(OOColor.ink)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(kind == .failure ? OOColor.failureText : OOColor.ink)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkSecondary)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OOSpace.large)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                kind == .decision ? OOColor.decisionFill : OOColor.failureFill
                if kind == .decision {
                    OOColor.decisionMark.frame(width: 3)
                }
            }
            .clipShape(shape)
        }
        .overlay(shape.stroke(kind == .decision ? OOColor.decisionLine : OOColor.failureLine, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.heading(kind))
    }

    private var mark: Color {
        kind == .decision ? OOColor.decisionMark : OOColor.failureMark
    }

    static func heading(_ kind: Kind) -> String {
        kind == .decision ? "Decision needed" : "Something went wrong"
    }
}

public extension OONotice where Actions == EmptyView {
    init(_ kind: Kind, title: String, message: String? = nil) {
        self.init(kind, title: title, message: message) { EmptyView() }
    }
}

#Preview("Notices") {
    OOPreviewPair {
        VStack(spacing: 12) {
            OONotice(.decision, title: "Run rm -rf build", message: "The agent wants to delete the build folder.") {
                Button("Approve once") {}.buttonStyle(.ooPrimary)
            }
            OONotice(.failure, title: "The agent stopped", message: "It is out of credits.")
        }
        .frame(width: 300)
    }
}
