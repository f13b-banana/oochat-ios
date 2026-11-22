import SwiftUI

/// The pane of an agent that asks for an invite code before it connects. A Claude Station uses its pairing
/// code here; the same code attaches the session afterwards.
struct OnboardingPaneView: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void
    @State private var code = ""

    private var isStation: Bool {
        viewModel.activeAgent.map(viewModel.isStation) ?? false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let prompt = viewModel.activeOnboarding {
                    content(prompt)
                        .padding(20)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ChatBanners(viewModel: viewModel)
            }
            .navigationTitle(viewModel.activeAgent?.name ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsSidebarButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onOpenSidebar) {
                            Image(systemName: "sidebar.left")
                        }
                        .accessibilityLabel("Open sidebar")
                    }
                }
            }
        }
        .onChange(of: viewModel.activeConversationID) { code = "" }
    }

    @ViewBuilder
    private func content(_ prompt: OnboardingPrompt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Access verification required", systemImage: "lock.shield.fill")
                .font(.headline)
            if prompt.acceptsInviteCode {
                Text(isStation
                    ? "Enter the pairing code your terminal printed."
                    : "Enter the invite code for this agent. If it was started with a Claude Station, "
                        + "enter the pairing code it printed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SecureField(isStation ? "Pairing code" : "Invite code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("onboarding-code-field")
                if let message = prompt.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("onboarding-error")
                }
                Button(prompt.isSubmitting ? "Verifying…" : "Verify Invite Code") {
                    let submitted = code
                    code = ""
                    viewModel.submitInviteCode(submitted)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.isSubmitting)
                .accessibilityIdentifier("onboarding-submit")
            } else {
                Text("This agent asks for a payment, which this app does not support.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
