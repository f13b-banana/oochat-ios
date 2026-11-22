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
    /// Why Add failed, or why a scanned code was refused. Shown in the footer, in red.
    @State private var formError: String?
    /// The camera can't scan here. Said quietly: typing or pasting the address still works.
    @State private var scannerNotice: String?
    @State private var isPresentingScanner = false
    @State private var scannedAddress: String?
    @State private var isFetchingAgentName = false
    /// The name the lookup filled in, so a later lookup only replaces its own guess.
    @State private var fetchedName: String?
    @FocusState private var isAddressFocused: Bool
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

    private var isNew: Bool {
        draft.agentID == nil
    }

    private var address: String {
        draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidAddress: Bool {
        AgentAddress.normalized(address) != nil
    }

    /// Said as soon as the address can't become valid, or once you've left the field half typed.
    private var addressProblem: String? {
        guard !address.isEmpty, !isValidAddress else {
            return nil
        }
        guard !AgentAddressInput.couldBecomeValid(address) || !isAddressFocused else {
            return nil
        }
        return "That doesn't look like an agent address."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    addressRow
                } header: {
                    Text("Address")
                } footer: {
                    footer
                }

                Section("Name") {
                    HStack {
                        TextField(
                            "Name",
                            text: $draft.name,
                            prompt: Text(isFetchingAgentName ? "Looking up…" : "Optional")
                                .foregroundStyle(OOColor.inkSecondary)
                        )
                        .textInputAutocapitalization(.words)
                        .foregroundStyle(OOColor.ink)
                        .accessibilityLabel("Name")
                        if isFetchingAgentName {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Looking up agent name")
                        }
                    }
                }
            }
            .animation(AppMotion.contentArrival(reduceMotion: reduceMotion), value: addressProblem)
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!isValidAddress)
                        .accessibilityIdentifier("agentForm.confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .fullScreenCover(isPresented: $isPresentingScanner) {
            AgentQRCodeScannerView(
                onCode: handleScannedCode,
                onUnavailable: handleScannerUnavailable
            )
        }
        .onChange(of: draft.address) {
            formError = nil
            if draft.address != scannedAddress {
                draft.shouldConnectAfterSave = false
            }
        }
        .task(id: isValidAddress ? address.lowercased() : nil) {
            await lookUpName()
        }
        .onAppear {
            if isNew {
                isAddressFocused = true
            }
        }
    }

    private var addressRow: some View {
        HStack(spacing: OOSpace.small) {
            TextField(
                "Agent address",
                text: $draft.address,
                prompt: Text("0x…").foregroundStyle(OOColor.inkSecondary),
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .font(OOFont.mono())
            .foregroundStyle(OOColor.ink)
            .focused($isAddressFocused)
            .accessibilityLabel("Agent address")

            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return
                }
                // A copied share link or QR text pastes as the address inside it.
                draft.address = AgentQRCodePayload.address(from: pasted) ?? pasted
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(OOColor.primary)

            if isNew {
                Button(action: scan) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.body.weight(.medium))
                        .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(OOColor.primary)
                .accessibilityLabel("Scan QR Code")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: OOSpace.tiny) {
            if let problem = formError ?? addressProblem {
                Text(problem)
                    .foregroundStyle(OOColor.failureText)
                    .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
            }
            if let scannerNotice {
                Text(scannerNotice)
                    .foregroundStyle(OOColor.inkSecondary)
            }
            Text("Starts with 0x. Find it in your agent's terminal, or scan its QR code.")
                .foregroundStyle(OOColor.inkSecondary)
        }
    }

    private func scan() {
        guard AgentQRCodeScannerView.isSupported else {
            scannerNotice = "This device can't scan. Paste or type the address instead."
            return
        }
        isPresentingScanner = true
    }

    private func save() {
        guard isValidAddress else {
            return
        }
        if !onSave(draft) {
            formError = isNew ? "Couldn't add this agent. Check the address and try again."
                : "Couldn't save this agent. Check the address and try again."
        }
    }

    private func handleScannedCode(_ code: String) {
        isPresentingScanner = false
        guard let address = AgentQRCodePayload.address(from: code) else {
            formError = "That QR code doesn't hold an agent address."
            return
        }

        scannedAddress = address
        draft.address = address
        draft.shouldConnectAfterSave = true
        scannerNotice = nil
    }

    private func handleScannerUnavailable(_ message: String) {
        isPresentingScanner = false
        scannerNotice = message
    }

    /// Fills the name for any valid address, unless you've typed one of your own.
    /// Each new address starts this again and cancels the last run, so the spinner is cleared up
    /// front: a cancelled run leaves it alone, or it would hide the spinner of the run after it.
    private func lookUpName() async {
        isFetchingAgentName = false
        guard isValidAddress else {
            return
        }
        let lookedUp = address
        guard draft.name.isEmpty || draft.name == fetchedName else {
            return
        }
        isFetchingAgentName = true
        defer {
            if !Task.isCancelled {
                isFetchingAgentName = false
            }
        }
        guard let name = await fetchAgentName(lookedUp),
              !Task.isCancelled,
              address == lookedUp,
              draft.name.isEmpty || draft.name == fetchedName else {
            return
        }
        draft.name = name
        fetchedName = name
    }
}

enum AgentAddressInput {
    /// True while what's typed is still the start of an address: finished with zeros, the kit's
    /// address rule (AgentAddress) accepts it.
    static func couldBecomeValid(_ text: String) -> Bool {
        let template = "0x" + String(repeating: "0", count: 64)
        return AgentAddress.normalized(text + template.dropFirst(text.count)) != nil
    }
}

extension View {
    /// The add or edit agent sheet, open while `draft` is set. A save that returns true closes it.
    func agentFormSheet(
        _ draft: Binding<AgentFormDraft?>,
        fetchAgentName: @escaping (String) async -> String?,
        onSave: @escaping (AgentFormDraft) -> Bool
    ) -> some View {
        sheet(item: draft) { current in
            AgentFormView(draft: current) { saved in
                guard onSave(saved) else {
                    return false
                }
                draft.wrappedValue = nil
                return true
            } onCancel: {
                draft.wrappedValue = nil
            } fetchAgentName: { address in
                await fetchAgentName(address)
            }
        }
    }
}
