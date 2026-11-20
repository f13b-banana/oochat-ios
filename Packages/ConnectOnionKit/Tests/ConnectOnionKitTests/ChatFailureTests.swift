import XCTest
@testable import ConnectOnionKit

final class ChatFailureTests: XCTestCase {
    private let address = "0x965743aea97b1f052bf05a5a18ceeb2cda6c486fd621c1c34f51529f260ba9a7"

    func testEachKnownFailureHasAPlainSentence() {
        XCTAssertEqual(ChatFailure.agentOffline.sentence(agentName: "PCAgent"), "PCAgent is offline.")
        XCTAssertEqual(ChatFailure.timedOut.sentence(agentName: "PCAgent"), "PCAgent didn't reply in time.")
        XCTAssertEqual(
            ChatFailure.notRecovered.sentence(agentName: "PCAgent"),
            "The connection dropped before the reply arrived. Your message wasn't resent."
        )
        XCTAssertNil(ChatFailure.agentOffline.details)
    }

    func testTheHostsReconnectMessageIsRewritten() {
        let raw = "Agent not connected: \(address); reconnect with a fresh CONNECT"
        let failure = ChatFailure.server(raw)

        XCTAssertEqual(failure.sentence(agentName: "PCAgent"), "Lost the connection to PCAgent. Retry to reconnect.")
        XCTAssertEqual(failure.details, raw)
    }

    func testUnknownTextKeepsItsWordsButNotTheLongAddress() {
        let failure = ChatFailure.server("Session \(address) is busy")

        XCTAssertEqual(failure.sentence(agentName: "PCAgent"), "Session 0x9657…a9a7 is busy")
        XCTAssertEqual(ChatFailure.shortenAddresses(in: "no address here"), "no address here")
    }

    func testEmptyTextFallsBackToASentence() {
        XCTAssertEqual(
            ChatFailure.server("  ").sentence(agentName: "PCAgent"),
            "PCAgent reported a problem but didn't say what."
        )
        XCTAssertEqual(ChatFailure.other("").sentence(agentName: "PCAgent"), "Something went wrong talking to PCAgent.")
        XCTAssertNil(ChatFailure.other("").details)
    }
}
