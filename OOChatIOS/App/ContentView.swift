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

    var body: some View {
        ChatShellView(viewModel: viewModel)
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
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
    }
}
