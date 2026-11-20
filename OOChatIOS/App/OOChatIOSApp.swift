import ConnectOnionKit
import SwiftUI

// The entry of app.
@main
struct OOChatIOSApp: App {
    // Owned here so the URL handler and the view share one view model.
    // `ContentView` takes it as a @StateObject, matching how it was constructed
    // before — ChatViewModel is an ObservableObject, not @Observable.
    @StateObject private var viewModel = ChatViewModel()

    init() {
        OOFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                // An `openonion://agent/0x…` link adds the agent and selects it, so
                // an address can be handed over in an email or from a web page
                // instead of being typed out as 64 hex characters.
                //
                // The link is only a carrier: `saveAgent` still validates the
                // address and surfaces the same message as manual entry, so a bad
                // link fails the way a bad paste does rather than silently.
                .onOpenURL { url in
                    guard let link = AgentLink(url: url) else { return }
                    if let saved = viewModel.saveAgent(
                        name: link.name ?? "",
                        address: link.address
                    ) {
                        viewModel.selectAgent(saved)
                    }
                }
        }
    }
}
