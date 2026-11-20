import Foundation
import XCTest
@testable import ConnectOnionKit

final class SessionStateMachineTests: XCTestCase {

    private let everyState: [SessionState] = [
        .idle,
        .connecting(attempt: 0),
        .connecting(attempt: 2),
        .connected,
        .failed(.offline),
        .failed(.ended),
        .failed(.incompatible)
    ]

    // Rule 1
    func testCloseReturnstoIdleFromEveryState() {
        for state in everyState {
            XCTAssertEqual(reduce(state, .close), .idle, "\(state)")
        }
    }

    // Rule 2
    func testOpenStartsFromIdleorFailed() {
        XCTAssertEqual(reduce(.idle, .open), .connecting(attempt: 0))
        XCTAssertEqual(reduce(.failed(.offline), .open), .connecting(attempt: 0))
        XCTAssertEqual(reduce(.failed(.ended), .open), .connecting(attempt: 0))
        XCTAssertEqual(reduce(.failed(.incompatible), .open), .connecting(attempt: 0))
    }

    // Rule 3
    func testConnectedFrameFinishes() {
        XCTAssertEqual(reduce(.connecting(attempt: 0), .connectedFrame), .connected)
        XCTAssertEqual(reduce(.connecting(attempt: 3), .connectedFrame), .connected)
    }

    // Rule 4
    func testConnectionLostWhileConnctedStartsRetry() {
        XCTAssertEqual(reduce(.connected, .socketClosed), .connecting(attempt: 1))
    }

    func testConnectionLostWithNoRetryGoesOffline() {
        XCTAssertEqual(reduce(.connected, .socketClosed, maxAttempts: 1), .failed(.offline))
    }

    // Rules 5 and 6
    func testFourAttemptsThenOffline() {
        var state = reduce(.idle, .open)
        var seen = [state]

        while case .connecting = state {
            state = reduce(state, .socketClosed)
            seen.append(state)
        }

        XCTAssertEqual(seen, [
            .connecting(attempt: 0),
            .connecting(attempt: 1),
            .connecting(attempt: 2),
            .connecting(attempt: 3),
            .failed(.offline)
        ])
    }

    // Rule 7
    func testIncompatibleVersionFailsWithoutRetry() {
        XCTAssertEqual(reduce(.connecting(attempt: 0), .incompatibleError), .failed(.incompatible))
        XCTAssertEqual(reduce(.connected, .incompatibleError), .failed(.incompatible))
        XCTAssertEqual(reduce(.failed(.incompatible), .socketClosed), .failed(.incompatible))
    }

    // Rule 8
    func testNotFoundEndsSession() {
        XCTAssertEqual(reduce(.connecting(attempt: 1), .notFound), .failed(.ended))
        XCTAssertEqual(reduce(.connected, .notFound), .failed(.ended))
    }

    // Rule 9
    func testStateNotChanging() {
        XCTAssertEqual(reduce(.idle, .socketClosed), .idle)
        XCTAssertEqual(reduce(.idle, .connectedFrame), .idle)
        XCTAssertEqual(reduce(.idle, .incompatibleError), .idle)
        XCTAssertEqual(reduce(.idle, .notFound), .idle)

        XCTAssertEqual(reduce(.connected, .open), .connected)
        XCTAssertEqual(reduce(.connected, .connectedFrame), .connected)

        XCTAssertEqual(reduce(.connecting(attempt: 1), .open), .connecting(attempt: 1))

        XCTAssertEqual(reduce(.failed(.offline), .socketClosed), .failed(.offline))
        XCTAssertEqual(reduce(.failed(.ended), .notFound), .failed(.ended))
    }

}
