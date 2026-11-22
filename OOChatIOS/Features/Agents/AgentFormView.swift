import SwiftUI
import ConnectOnionKit

struct AgentFormDraft: Identifiable {
    let id = UUID()
    let agentID: String?
    var name: String
    var address: String
    var shouldConnectAfterSave = false

    init(agent: SavedAgent? = nil) {
        self.agentID = agent?.id
        self.name = agent?.name ?? ""
        self.address = agent?.address ?? ""
    }

    var title: String {
        agentID == nil ? "Add Agent" : "Edit Agent"
    }
}

struct AgentFormView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: AgentFormDraft
    @State private var validationMessage: String?
    @State private var isPresentingScanner = false
    @State private var scannedAddress: String?
    @State private var isFetchingAgentName = false
    let onSave: (AgentFormDraft) -> Bool
    let onCancel: () -> Void
    let fetchAgentName: (String) async -> String?

    init(
        draft: AgentFormDraft,
        onSave: @escaping (AgentFormDraft) -> Bool,
        onCancel: @escaping () -> Void,
        fetchAgentName: @escaping (String) async -> String? = { _ in nil }
    ) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
        self.fetchAgentName = fetchAgentName
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    HStack {
                        TextField("Name", text: $draft.name, prompt: Text("Name").foregroundStyle(OOColor.inkSecondary))
                            .textInputAutocapitalization(.words)
                            .foregroundStyle(OOColor.ink)
                        if isFetchingAgentName {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Looking up agent name")
                        }
                    }
                    TextField(
                        "Agent address",
                        text: $draft.address,
                        prompt: Text("Agent address").foregroundStyle(OOColor.inkSecondary),
                        axis: .vertical
                    )
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(OOColor.ink)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: draft.address) {
                            validationMessage = nil
                            if draft.address != scannedAddress {
                                draft.shouldConnectAfterSave = false
                            }
                        }
                    if draft.agentID == nil {
                        Button {
                            guard AgentQRCodeScannerView.isSupported else {
                                validationMessage = "Camera scanning is unavailable. Enter the agent address manually."
                                return
                            }
                            isPresentingScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
                .animation(
                    AppMotion.contentArrival(reduceMotion: reduceMotion),
                    value: validationMessage
                )
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard HostedAgentClient.isHostedAgentAddress(
                            draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
                        ) else {
                            validationMessage = "Enter a hosted agent address in 0x-prefixed Ed25519 format."
                            return
                        }
                        if !onSave(draft) {
                            validationMessage = "Couldn't save this agent. Double-check that the address "
                                + "is a valid 0x-prefixed Ed25519 key, then try again."
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .fullScreenCover(isPresented: $isPresentingScanner) {
            AgentQRCodeScannerView(
                onCode: handleScannedCode,
                onUnavailable: handleScannerUnavailable
            )
        }
        .task(id: scannedAddress) {
            await populateNameFromScannedAgent()
        }
    }

    private func handleScannedCode(_ code: String) {
        isPresentingScanner = false
        guard let address = AgentQRCodePayload.address(from: code) else {
            validationMessage = "This QR code does not contain a valid agent address."
            return
        }

        scannedAddress = address
        draft.address = address
        draft.shouldConnectAfterSave = true
        validationMessage = nil
    }

    private func handleScannerUnavailable(_ message: String) {
        isPresentingScanner = false
        validationMessage = message
    }

    private func populateNameFromScannedAgent() async {
        guard let address = scannedAddress else {
            return
        }
        let originalName = draft.name
        isFetchingAgentName = true
        defer {
            if scannedAddress == address {
                isFetchingAgentName = false
            }
        }

        guard let name = await fetchAgentName(address),
              !Task.isCancelled,
              scannedAddress == address,
              draft.address == address,
              draft.name == originalName else {
            return
        }
        draft.name = name
    }
}
