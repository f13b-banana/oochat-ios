import ConnectOnionKit
import SwiftUI

/// Shown when the agent answered -32010. It states the problem once and offers no retry: the
/// protocol version is fixed in the app, so a second attempt would get the same answer.
struct IncompatibleAgentView: View {
    let incompatibility: OIPHandshake.Incompatibility
    var agentName: String?
    let onDismiss: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(incompatibility.title, systemImage: "exclamationmark.triangle.fill")
        } description: {
            VStack(spacing: 8) {
                if let agentName {
                    Text(agentName).font(.headline)
                }
                Text(incompatibility.message)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Agent needs")
                        Text(incompatibility.neededVersion.map { "OIP \($0)" } ?? "not stated")
                    }
                    GridRow {
                        Text("This app speaks")
                        Text(incompatibility.appVersion.map { "OIP \($0)" } ?? "unknown")
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Close", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("incompatibleAgentScreen")
    }
}

#Preview("Agent is newer") {
    IncompatibleAgentView(
        incompatibility: OIPHandshake.Incompatibility(neededVersion: "0.2", appVersion: "0.1"),
        agentName: "Live Agent",
        onDismiss: {}
    )
}
