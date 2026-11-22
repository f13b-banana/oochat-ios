import Combine
import ConnectOnionKit
import XCTest
@testable import OOChatIOS

@MainActor
final class AgentFormViewTests: XCTestCase {
    func testAddAgentFormRendersFieldsAndInvokesCancel() {
        var didCancel = false
        let window = ViewHost.host(
            AgentFormView(draft: AgentFormDraft()) { _ in
                XCTFail("unexpected save")
                return false
            } onCancel: {
                didCancel = true
            }
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Add Agent", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Name", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Agent address", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Scan QR Code", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Cancel", in: window))
        XCTAssertTrue(didCancel)
    }

    func testInvalidAddressDoesNotSave() {
        var didAttemptSave = false
        let window = ViewHost.host(
            AgentFormView(draft: makeDraft(address: "not-an-agent-address")) { _ in
                didAttemptSave = true
                return true
            } onCancel: {}
        )

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Save", in: window))
        ViewHost.pump(0.3)
        XCTAssertFalse(didAttemptSave)
    }

    func testSaveFailureKeepsFormOpenAfterSaveAttempt() {
        var saveAttemptCount = 0
        let window = ViewHost.host(
            AgentFormView(draft: makeDraft(address: hostedAddress)) { _ in
                saveAttemptCount += 1
                return false
            } onCancel: {}
        )

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Save", in: window))
        ViewHost.pump(0.3)
        XCTAssertEqual(saveAttemptCount, 1)
        XCTAssertNotNil(ViewHost.element(labelContains: "Add Agent", in: window))
    }

    func testEditAgentFormSavesExistingDraftWithoutScanner() {
        let agent = SavedAgent(
            id: "agent-edit",
            address: hostedAddress,
            name: "Orbit Agent",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        var savedDraft: AgentFormDraft?
        let window = ViewHost.host(
            AgentFormView(draft: AgentFormDraft(agent: agent)) { draft in
                savedDraft = draft
                return true
            } onCancel: {}
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Edit Agent", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Scan QR Code", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Save", in: window))
        XCTAssertEqual(savedDraft?.agentID, "agent-edit")
        XCTAssertEqual(savedDraft?.name, "Orbit Agent")
        XCTAssertEqual(savedDraft?.address, hostedAddress)
        XCTAssertEqual(savedDraft?.shouldConnectAfterSave, false)
    }

    func testViewModelFetchesAdvertisedAgentName() async {
        let transport = MockAgentTransport()
        transport.agentNamesByAddress[hostedAddress] = "Scanned Agent"
        let viewModel = ViewFixtures.chatViewModel(transport: transport)

        let name = await viewModel.fetchAgentName(for: hostedAddress)

        XCTAssertEqual(name, "Scanned Agent")
        XCTAssertEqual(transport.fetchedNameAddresses, [hostedAddress])
    }
}

@MainActor
final class SettingsViewTests: XCTestCase {
    func testSettingsShowsIdentitySessionAndInvokesActions() {
        let model = TestSettingsModel(
            identity: StoredIdentity(
                address: hostedAddress,
                publicKeyHex: String(repeating: "cd", count: 32),
                createdAt: Date(timeIntervalSince1970: 1_000)
            ),
            connectionState: .connected,
            activeConversation: conversation(id: "conversation-42")
        )
        var didClose = false
        let window = ViewHost.host(
            SettingsView(viewModel: model) {
                didClose = true
            }
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Settings", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Your address 0xaaaaaaaa", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "conversation-42", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Reconnect", in: window))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Reconnect", in: window))
        ViewHost.pump(0.2)
        XCTAssertEqual(model.reconnectCallCount, 1)

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Close", in: window))
        XCTAssertTrue(didClose)
    }

    func testIdentityOffersBothLinkRowsAndTheLinkSheetOpensAndCancels() {
        let model = TestSettingsModel(identity: nil, connectionState: .disconnected, activeConversation: nil)
        let window = ViewHost.host(SettingsView(viewModel: model))

        XCTAssertNotNil(ViewHost.element(labelContains: "Link from another device", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Link a new device", in: window))
        ViewHost.pump(0.5)

        // The iPhone opens on code entry in both roles, so opening the sheet starts no listener.
        XCTAssertNotNil(ViewHost.element(labelContains: "Link Code", in: window), "the giver's code entry is showing")
        XCTAssertNotNil(ViewHost.element(labelContains: "Show my code instead", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Cancel", in: window))
        ViewHost.pump(0.5)
        XCTAssertNil(ViewHost.element(labelContains: "Link Code", in: window), "Cancel closes the sheet")
    }

    func testFirstLaunchOffersANewIdentityOrLinkingFromAnotherDevice() {
        var finished = 0
        let window = ViewHost.host(
            IdentityOnboardingView(keyStore: InMemoryPrivateKeyStore(), onReplaced: { _ in }, onFinish: { finished += 1 })
        )

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Link from another device", in: window))
        ViewHost.pump(0.5)
        // The receive sheet from Settings: it opens on the scanner and says where the other device shows its code.
        XCTAssertNotNil(ViewHost.element(labelContains: "Link a new device", in: window), "the receive sheet is showing")
        XCTAssertNotNil(ViewHost.element(labelContains: "Show my code instead", in: window), "the receiver scans first")
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Cancel", in: window))
        ViewHost.pump(0.5)
        XCTAssertEqual(finished, 0, "closing the link sheet goes back to the choice")

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Create a new identity", in: window))
        XCTAssertEqual(finished, 1)
    }

    func testSettingsShowsPlaceholdersWhenIdentityAndSessionAreMissing() {
        let model = TestSettingsModel(
            identity: nil,
            connectionState: .disconnected,
            activeConversation: nil
        )
        let window = ViewHost.host(SettingsView(viewModel: model))

        XCTAssertNotNil(ViewHost.element(labelContains: "Creating...", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "None", in: window))
    }
}

@MainActor
final class AgentQRCodeShareViewTests: XCTestCase {
    func testShareViewRendersQRCodeScreen() throws {
        let url = try XCTUnwrap(AgentShareURL.url(for: hostedAddress))
        let window = ViewHost.host(AgentQRCodeShareView(url: url))

        XCTAssertNotNil(window.rootViewController)
    }
}

private let hostedAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private func makeDraft(
    name: String = "",
    address: String = ""
) -> AgentFormDraft {
    var draft = AgentFormDraft()
    draft.name = name
    draft.address = address
    return draft
}

private func conversation(id: String) -> Conversation {
    let agent = ViewFixtures.agent()
    return Conversation(
        id: id,
        title: "Settings Chat",
        agentID: agent.id,
        agentAddress: agent.address,
        mode: .safe,
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 2_000),
        messages: [],
        serverSession: nil
    )
}

@MainActor
private final class TestSettingsModel: SettingsFeatureModel {
    @Published var identity: StoredIdentity?
    @Published var connectionState: ConversationConnectionState
    @Published var activeConversation: Conversation?
    private(set) var reconnectCallCount = 0
    let deviceLinkKeyStore: any DeviceLinkKeyStore = InMemoryPrivateKeyStore()

    init(
        identity: StoredIdentity?,
        connectionState: ConversationConnectionState,
        activeConversation: Conversation?
    ) {
        self.identity = identity
        self.connectionState = connectionState
        self.activeConversation = activeConversation
    }

    func reconnect() async {
        reconnectCallCount += 1
    }

    func adoptReplacedIdentity(previousAddress: String) async {}

    let linkAgentNames: [DeviceLinkAgentName] = []

    func applyLinkedAgentNames(_ list: [DeviceLinkAgentName]) throws {}
}
