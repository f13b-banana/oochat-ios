import Foundation
import XCTest
@testable import ConnectOnionKit

final class OIPDashboardTests: XCTestCase {

    func testLimitsMatchTheHostAndThePlan() {
        XCTAssertEqual(OIPDashboard.socketMessageBytes, 268_435_456)
        XCTAssertEqual(OIPDashboard.clientCapBytes, 16_777_216)
    }

    func testPageAtTheCapIsShown() {
        let html = String(repeating: "a", count: OIPDashboard.clientCapBytes)

        XCTAssertEqual(OIPDashboard(html: html), .page(html: html))
    }

    func testOneByteOverTheCapIsTooLarge() {
        let html = String(repeating: "a", count: OIPDashboard.clientCapBytes + 1)

        XCTAssertEqual(OIPDashboard(html: html), .tooLarge(bytes: OIPDashboard.clientCapBytes + 1))
    }

    // The cap counts UTF-8 bytes, not characters: "é" is two bytes.
    func testCapCountsBytesNotCharacters() {
        let html = String(repeating: "é", count: OIPDashboard.clientCapBytes / 2 + 1)

        XCTAssertEqual(OIPDashboard(html: html), .tooLarge(bytes: OIPDashboard.clientCapBytes + 2))
    }

    func testTwoMebibytePageIsShown() {
        let html = String(repeating: "<p>x</p>", count: 2 * 1024 * 1024 / 8)

        XCTAssertEqual(OIPDashboard(html: html), .page(html: html))
    }
}
