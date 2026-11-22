import ConnectOnionKit
import SwiftUI

/// The detail pane for a Claude Station: its Work Room straight away, or the pairing field until it exists.
struct StationPaneView: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void
    @StateObject private var dictation: WorkRoomDictation

    init(viewModel: ChatViewModel, showsSidebarButton: Bool, onOpenSidebar: @escaping () -> Void) {
        self.viewModel = viewModel
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
        _dictation = StateObject(wrappedValue: WorkRoomDictation(controller: viewModel.voiceInputController))
    }

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    ChatBanners(viewModel: viewModel)
                }
                .navigationTitle(viewModel.activeAgent?.name ?? "Claude Station")
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
        .task(id: viewModel.activeConversationID) {
            viewModel.connectActiveConversationOnOpen()
        }
        .onChange(of: viewModel.activeConversationID) { dictation.cancel() }
        .onDisappear { dictation.cancel() }
    }

    @ViewBuilder private var content: some View {
        if let conversationID = viewModel.activeConversationID {
            let store = viewModel.conversationState.workRoomStore(for: conversationID)
            Group {
                if let workRoom = store.stationWorkRoom {
                    OOWorkRoomView(
                        workRoom: workRoom,
                        onDecide: { store.decide($0, in: workRoom.id) },
                        onStop: { store.stop(in: workRoom.id) },
                        onDraftChange: { store.setDraft($0, in: workRoom.id) },
                        onSend: { store.send(in: workRoom.id) },
                        onChangePermission: { store.changePermission(to: $0, confirmRisk: $1, in: workRoom.id) },
                        onChangeControl: { store.changeControl($0, in: workRoom.id) },
                        mic: OOWorkRoomMic(state: dictation.micState, guidance: dictation.guidance) {
                            dictation.toggle(in: workRoom.id) { _ = store.appendDictation($0, in: workRoom.id) }
                        }
                    )
                    .onChange(of: workRoom.composer.canDictate) { _, canDictate in
                        if !canDictate { dictation.cancel() }
                    }
                } else if store.stationPairing.needsCode {
                    ScrollView {
                        OOStationPairingView(pairing: store.stationPairing, onPair: { store.pairStation(code: $0) })
                    }
                } else {
                    // The remembered code is on its way, or the host accepted it and the session is opening.
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Opening your Claude Code session")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: store.stationPairing.sessionID, initial: true) { _, sessionID in
                if let sessionID, let agent = viewModel.activeAgent {
                    viewModel.openStationSession(sessionID, for: agent)
                }
            }
        }
    }
}
