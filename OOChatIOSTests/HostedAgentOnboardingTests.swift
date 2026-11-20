import ConnectOnionKit
import Foundation
import XCTest
@testable import OOChatIOS

extension HostedAgentConnectionTests {
    private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testOnboardRequiredKeepsTheConnectionOpenAndSubmitsTheCode() async throws {
        let factory = MockHostedAgentSocketFactory()
        let observer = HostedAgentConnectionStateObserver()
        var updates: [HostedAgentSessionUpdate] = []
        observer.updateHandler = { _, update in updates.append(update) }
        let connection = makeConnection(factory: factory, observer: observer)
        let conversation = makeConversation(id: "onboard")
        let connectTask = Task { try await connection.ensureConnected(conversation: conversation) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")

        try socket.enqueueFrame(KitFixtures.frame("ONBOARD_REQUIRED"))
        // The agent can be saved while the prompt is open: the connect does not fail.
        let placeholder = try await connectTask.value
        XCTAssertNil(placeholder.output)
        try await settle { updates.contains { if case .onboarding(.required) = $0 { true } else { false } } }
        XCTAssertNil(socket.closeCode)

        try await connection.submitOnboarding(code: "wrong")
        let submit = try await socket.waitForSentFrame(type: "ONBOARD_SUBMIT")
        XCTAssertEqual(submit["invite_code"]?.stringValue ?? submit["payload"]?.objectValue?["invite_code"]?.stringValue, "wrong")

        try socket.enqueueFrame(["type": .string("ERROR"), "message": .string("Invalid invite code")])
        try await settle { updates.contains(.onboarding(.rejected("Invalid invite code"))) }
        XCTAssertNil(socket.closeCode)

        try socket.enqueueFrame(KitFixtures.frame("ONBOARD_SUCCESS"))
        try await settle { updates.contains(.onboarding(.granted)) }
        // The host replays CONNECT itself: no second CONNECT goes out.
        try socket.enqueueFrame(["type": .string("CONNECTED"), "session_id": .string("onboard"), "status": .string("connected")])
        let connected = try await connection.ensureConnected(conversation: conversation)
        XCTAssertEqual(connected.serverSession?["session_id"]?.stringValue, "onboard")
        XCTAssertEqual(try socket.sentFrames().filter { $0["type"]?.stringValue == "CONNECT" }.count, 1)
        await connection.close()
    }

    func testNoPromptIsSentWhileTheHostWaitsForAnInviteCode() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "onboard-input")
        let connectTask = Task { try await connection.ensureConnected(conversation: conversation) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(KitFixtures.frame("ONBOARD_REQUIRED"))
        _ = try await connectTask.value

        do {
            _ = try await connection.sendPrompt(
                conversation: conversation, prompt: "hi", images: [], files: [], onEvent: nil, onInteraction: nil
            )
            XCTFail("a prompt must not be sent before onboarding")
        } catch HostedAgentClientError.onboardingRequired {
        }
        XCTAssertFalse(try socket.sentFrames().contains { $0["type"]?.stringValue == "INPUT" })
        await connection.close()
    }

    func testProviderStationOnlyErrorReachesTheStoreAndKeepsTheConnection() async throws {
        let factory = MockHostedAgentSocketFactory()
        let observer = HostedAgentConnectionStateObserver()
        var frames: [OIPServerFrame] = []
        observer.providerHandler = { _, update in
            if case .frame(let frame) = update {
                frames.append(frame)
            }
        }
        let connection = makeConnection(factory: factory, observer: observer)
        let conversation = makeConversation(id: "station-only")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)

        try socket.enqueueFrame([
            "type": .string("ERROR"), "code": .string("provider_station_only"), "message": .string("Station only")
        ])
        try await settle { !frames.isEmpty }
        XCTAssertNil(socket.closeCode)
        _ = try await connection.ensureConnected(conversation: conversation)
        XCTAssertEqual(factory.count, 1)
        await connection.close()
    }
}
