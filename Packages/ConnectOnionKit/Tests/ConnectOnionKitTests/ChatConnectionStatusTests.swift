import XCTest
@testable import ConnectOnionKit

final class ChatConnectionStatusTests: XCTestCase {
    private func status(
        _ state: SessionState,
        host: String? = nil,
        connectingFor: TimeInterval = 0
    ) -> ChatConnectionStatus {
        ChatConnectionStatus(state: state, hostStatus: host, connectingFor: connectingFor)
    }

    func testConnectedIsLiveOrWorking() {
        XCTAssertEqual(status(.connected).label, "Live")
        XCTAssertEqual(status(.connected, host: "new").label, "Live")
        XCTAssertEqual(status(.connected, host: "running").label, "Working…")
        XCTAssertTrue(status(.connected).isLive)
        XCTAssertTrue(status(.connected, host: "running").isLive)
    }

    func testConnectingTurnsIntoCantConnectAfterTenSeconds() {
        XCTAssertEqual(status(.connecting(attempt: 0), connectingFor: 9).label, "Connecting…")
        XCTAssertEqual(status(.connecting(attempt: 0), connectingFor: 10), .unreachable(.noAnswer))
        // A reconnect after a drop counts the same.
        XCTAssertEqual(status(.connecting(attempt: 2), connectingFor: 12).label, "Can't connect")
        XCTAssertFalse(status(.connecting(attempt: 0)).isLive)
    }

    func testFailuresAndIdleHaveTheirOwnWords() {
        XCTAssertEqual(status(.failed(.offline)).label, "No network")
        XCTAssertEqual(status(.failed(.ended)).label, "Session ended")
        XCTAssertEqual(status(.failed(.incompatible)).label, "Agent needs an update")
        XCTAssertEqual(status(.idle).label, "Not connected")
    }

    func testOnlyStatesARetryCanFixOfferRetry() {
        XCTAssertTrue(status(.idle).canRetry)
        XCTAssertTrue(status(.connecting(attempt: 0), connectingFor: 10).canRetry)
        XCTAssertTrue(status(.failed(.offline)).canRetry)
        XCTAssertFalse(status(.failed(.ended)).canRetry)
        XCTAssertFalse(status(.failed(.incompatible)).canRetry)
        XCTAssertFalse(status(.connected).canRetry)
        XCTAssertFalse(status(.connecting(attempt: 0)).canRetry)
    }

    func testDotIsGreenLiveRedFailedGreyWaiting() {
        XCTAssertEqual(status(.connected).tone, .live)
        XCTAssertEqual(status(.connecting(attempt: 0)).tone, .neutral)
        XCTAssertEqual(status(.idle).tone, .neutral)
        XCTAssertEqual(status(.connecting(attempt: 0), connectingFor: 10).tone, .failure)
        XCTAssertEqual(status(.failed(.offline)).tone, .failure)
        XCTAssertEqual(status(.failed(.ended)).tone, .failure)
    }

    func testDetailNamesTheAgentAndTheLikelyCause() {
        let detail = status(.connecting(attempt: 0), connectingFor: 30).detail(agentName: "PCAgent")
        XCTAssertTrue(detail.contains("PCAgent"))
        XCTAssertTrue(detail.contains("hasn't accepted this device"))
    }
}
