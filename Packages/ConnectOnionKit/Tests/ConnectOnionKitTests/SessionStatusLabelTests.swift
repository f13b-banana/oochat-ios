import Foundation
import XCTest
@testable import ConnectOnionKit

final class SessionStatusLabelTests: XCTestCase {
    func testConnectedFollowsTheHostStatus() {
        XCTAssertEqual(SessionStatusLabel.text(state: .connected, hasBookmark: true, hostStatus: "running"), "Running")
        XCTAssertEqual(SessionStatusLabel.text(state: .connected, hasBookmark: false, hostStatus: "new"), "New session")
        XCTAssertEqual(SessionStatusLabel.text(state: .connected, hasBookmark: true, hostStatus: "connected"), "Connected")
        XCTAssertEqual(SessionStatusLabel.text(state: .connected, hasBookmark: true, hostStatus: nil), "Connected")
    }

    // A stale "running" must not hide a dropped socket.
    func testSocketStateWinsOverTheHostStatus() {
        XCTAssertEqual(SessionStatusLabel.text(state: .connecting(attempt: 2), hasBookmark: true, hostStatus: "running"), "Reconnecting")
        XCTAssertEqual(SessionStatusLabel.text(state: .connecting(attempt: 0), hasBookmark: true, hostStatus: nil), "Resuming")
        XCTAssertEqual(SessionStatusLabel.text(state: .connecting(attempt: 0), hasBookmark: false, hostStatus: nil), "Connecting")
        XCTAssertEqual(SessionStatusLabel.text(state: .failed(.offline), hasBookmark: true, hostStatus: "running"), "Offline")
        XCTAssertEqual(SessionStatusLabel.text(state: .failed(.ended), hasBookmark: true, hostStatus: nil), "Ended")
        XCTAssertEqual(SessionStatusLabel.text(state: .failed(.incompatible), hasBookmark: false, hostStatus: nil), "Incompatible")
        XCTAssertEqual(SessionStatusLabel.text(state: .idle, hasBookmark: false, hostStatus: nil), "Not Connected")

    }

    func testPollingStopsOnceTheRunIsOver() {
        XCTAssertTrue(SessionStatusLabel.keepsPolling(after: "running"))
        XCTAssertFalse(SessionStatusLabel.keepsPolling(after: "connected"))
        XCTAssertFalse(SessionStatusLabel.keepsPolling(after: "not_found"))
        XCTAssertEqual(SessionStatusLabel.pollInterval, 10)
    }

    func testNotFoundEndsTheSession() {
        XCTAssertEqual(SessionStatusLabel.event(for: "not_found").map {reduce(.connected, $0) }, .failed(.ended))
        XCTAssertNil(SessionStatusLabel.event(for: "running"))
        XCTAssertNil(SessionStatusLabel.event(for: "connected"))
    }
}
