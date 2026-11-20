import ConnectOnionKit
import XCTest
@testable import OOChatIOS

@MainActor
final class ChatViewModelOnboardingTests: XCTestCase {
    private let address = "0x" + String(repeating: "a", count: 64)

    private struct Setup {
        let viewModel: ChatViewModel
        let transport: MockAgentTransport
        let agent: SavedAgent
        let conversationID: String
    }

    private func makeSetup() throws -> Setup {
        let suite = "OOChatIOSTests.\(UUID().uuidString)"
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        let transport = MockAgentTransport()
        let viewModel = ChatViewModel(store: store, client: transport, networkMonitor: MockNetworkMonitor())
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Station", address: address))
        return Setup(viewModel: viewModel, transport: transport, agent: agent, conversationID: viewModel.createConversation(for: agent).id)
    }

    private func required() throws -> OIPOnboardRequired {
        guard case .onboardRequired(let value) = OIPServerFrame.decode(try KitFixtures.frame("ONBOARD_REQUIRED")) else {
            throw HostedAgentTestError.timedOut
        }
        return value
    }

    func testInviteCodeIsSubmittedAndAWrongCodeCanBeRetried() async throws {
        let setup = try makeSetup()
        let (viewModel, transport, conversationID) = (setup.viewModel, setup.transport, setup.conversationID)
        viewModel.applyOnboarding(.required(try required()), forConversationID: conversationID)
        XCTAssertEqual(viewModel.activeOnboarding?.acceptsInviteCode, true)

        viewModel.submitInviteCode("  secret ")
        XCTAssertEqual(viewModel.activeOnboarding?.isSubmitting, true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.submittedOnboardingCodes, ["secret"])

        viewModel.applyOnboarding(.rejected("Invalid invite code"), forConversationID: conversationID)
        XCTAssertEqual(viewModel.activeOnboarding?.message, "Invalid invite code")
        XCTAssertEqual(viewModel.activeOnboarding?.isSubmitting, false)

        viewModel.applyOnboarding(.granted, forConversationID: conversationID)
        XCTAssertNil(viewModel.activeOnboarding)
    }

    func testAStationNeverGetsAnOuterInput() throws {
        let setup = try makeSetup()
        let (viewModel, transport, agent) = (setup.viewModel, setup.transport, setup.agent)
        ChatViewModel.rememberStationAddress(agent.address)
        defer { UserDefaults.standard.removeObject(forKey: "ClaudeStationAddresses") }
        XCTAssertTrue(viewModel.isStation(agent))

        viewModel.prompt = "hello"
        viewModel.sendPrompt()

        XCTAssertTrue(transport.sentPrompts.isEmpty)
    }
}
