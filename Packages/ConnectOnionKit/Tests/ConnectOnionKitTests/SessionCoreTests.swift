import Foundation
import XCTest
@testable import ConnectOnionKit

final class ReconnectPolicyTests: XCTestCase {

    func testAttemptDefaults() throws {
        let policy = ReconnectPolicy()

        XCTAssertEqual(policy.maxAttempts, 4)
        XCTAssertEqual(policy.baseDelay, 1)
        XCTAssertEqual(policy.maxDelay, 16)
    }

    func testDelayDoubles() throws {
        let policy = ReconnectPolicy()

        XCTAssertEqual((0...5).map(policy.delay(for:)), [0, 1, 2, 4, 8, 16])
    }

    func testDelayNeverExceedsCap() throws {
        let policy = ReconnectPolicy()

        XCTAssertEqual(policy.delay(for: 6), 16)
        XCTAssertEqual(policy.delay(for: 1000), 16)
        XCTAssertEqual(policy.delay(for: .max), 16)
    }

    func testNegativeAttempt() throws {
        XCTAssertEqual(ReconnectPolicy().delay(for: -1), 0)
    }

    // iOS has a custom Base
    func testCustomBaseAndCap() {
        let policy = ReconnectPolicy(maxAttempts: 2, baseDelay: 0.5, maxDelay: 1.5)

        XCTAssertEqual(policy.maxAttempts, 2)
        XCTAssertEqual((1...4).map(policy.delay(for: )), [0.5, 1, 1.5, 1.5])
    }

    func testStateMachineAttemptsMatchSocketAttempts() {
        let policy = ReconnectPolicy()
        var state = reduce(.idle, .open, maxAttempts: policy.maxAttempts)
        var attempts = 0

        while case .connecting = state {
            attempts += 1
            state = reduce(state, .socketClosed, maxAttempts: policy.maxAttempts)
        }

        XCTAssertEqual(attempts, policy.maxAttempts)
        XCTAssertEqual(state, .failed(.offline))
    }
}

final class EventLedgerTests: XCTestCase {

    func testFirstSightingIsNewAndRepeatIsReplay() {
        var ledger = EventLedger()

        XCTAssertTrue(ledger.record(eventID: "tool_call:1"))
        XCTAssertFalse(ledger.record(eventID: "tool_call:1"))
    }

    func testCallAndResultShareID() {
        var ledger = EventLedger()

        XCTAssertTrue(ledger.record(eventID: "tool_call:1"))
        XCTAssertTrue(ledger.record(eventID: "tool_result:1"))
    }

    func testReplays() {
        var ledger = EventLedger(previouslySeen: ["thinking:7"])

        XCTAssertFalse(ledger.record(eventID: "thinking:7"))
        XCTAssertTrue(ledger.record(eventID: "thinking:8"))
    }

    func testCopiesDoNotShareHistory() {
        var original = EventLedger()
        var copy = original

        XCTAssertTrue(copy.record(eventID: "plan:1"))
        XCTAssertTrue(original.record(eventID: "plan:1"))
    }
}

final class SessionBookmarkTests: XCTestCase {

    func testRoundTripJSON() throws {
        let bookmark = SessionBookmark(sessionID: "session-1", lastMessageID: "msg-9")

        let decoded = try JSONDecoder().decode(SessionBookmark.self, from: JSONEncoder().encode(bookmark))

        XCTAssertEqual(decoded, bookmark)
    }

    // iOS stores bookmarks as this JSON
    func testDecodesStoredShape() throws {
        let stored = Data(#"{"sessionID":"session-1","lastMessageID":"msg-9"}"#.utf8)

        XCTAssertEqual(try JSONDecoder().decode(SessionBookmark.self, from: stored),
                       SessionBookmark(sessionID: "session-1", lastMessageID: "msg-9")
        )
    }

    func testBookmarkWithoutMessageDecodes() throws {
        let stored = Data(#"{"sessionID":"session-1"}"#.utf8)

        XCTAssertNil(try JSONDecoder().decode(SessionBookmark.self, from: stored).lastMessageID)
    }

    func testMissingSessionIDFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(SessionBookmark.self, from: Data(#"{"lastMessageID":"m"}"#.utf8)))
    }

    func testLastMessageIDAdvances() {
        var bookmark = SessionBookmark(sessionID: "session-1")

        bookmark.lastMessageID = "msg-1"
        bookmark.lastMessageID = "msg-2"

        XCTAssertEqual(bookmark, SessionBookmark(sessionID: "session-1", lastMessageID: "msg-2"))
    }
}
