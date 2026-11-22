import SwiftUI

// In charge of organizing the main chat shell.
struct ContentView: View {
    // Observed, not owned: OOChatIOSApp holds it so the URL handler and this view
    // act on the same view model. A @StateObject initialised from a parameter
    // keeps only the first value it is given, which is a quiet way to end up with
    // two of them.
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue
    /// Set once the person has kept this device's Identity or linked one in. Someone who already has
    /// agents never sees onboarding, so upgrading doesn't show it.
    @AppStorage("identityOnboardingDone") private var isOnboardingDone = false
    /// A link from onboarding adds the giver's agents before its sheet is done, so onboarding stays up until then.
    @State private var isOnboardingLinking = false

    var body: some View {
        ChatShellView(viewModel: viewModel)
        .fullScreenCover(isPresented: Binding(
            get: { !isOnboardingDone && (viewModel.agents.isEmpty || isOnboardingLinking) },
            set: { if !$0 { isOnboardingDone = true } }
        )) {
            IdentityOnboardingView(
                keyStore: viewModel.deviceLinkKeyStore,
                onReplaced: { previousAddress in
                    Task { await viewModel.adoptReplacedIdentity(previousAddress: previousAddress) }
                },
                onAgentNames: { names in
                    isOnboardingLinking = true
                    try viewModel.applyLinkedAgentNames(names)
                },
                onFinish: { isOnboardingDone = true }
            )
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 1) {
                if viewModel.shouldShowOfflineBanner {
                    OfflineBanner(isRetrying: viewModel.isRetryingConnectivity) {
                        viewModel.retryConnectivity()
                    } onDismiss: {
                        viewModel.dismissOfflineBanner()
                    }
                    .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
                }
                ErrorBanner(message: viewModel.errorMessage) {
                    viewModel.dismissError()
                }
            }
        }
        .animation(
            AppMotion.contentArrival(reduceMotion: reduceMotion),
            value: viewModel.shouldShowOfflineBanner
        )
        .animation(
            AppMotion.contentArrival(reduceMotion: reduceMotion),
            value: viewModel.errorMessage
        )
        .fullScreenCover(
            isPresented: Binding(
                get: { viewModel.incompatibility != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissIncompatibility()
                    }
                }
            )
        ) {
            if let incompatibility = viewModel.incompatibility {
                IncompatibleAgentView(incompatibility: incompatibility) {
                    viewModel.dismissIncompatibility()
                }
            }
        }
        .tint(AppTheme.primary)
        .preferredColorScheme(AppAppearance(rawValue: appAppearance)?.colorScheme)
        .onAppear {
            if AppAppearance(rawValue: appAppearance) == nil {
                appAppearance = AppAppearance.system.rawValue
            }
        }
        // Having agents outside an onboarding link means onboarding is past, so deleting the
        // last one later doesn't bring the first-launch cover back.
        .onChange(of: viewModel.agents.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty && !isOnboardingLinking { isOnboardingDone = true }
        }
        .task { await viewModel.refreshHistory() }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
    }
}
