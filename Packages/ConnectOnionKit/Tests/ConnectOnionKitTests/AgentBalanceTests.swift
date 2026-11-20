//
//  AgentBalanceTests.swift
//  ConnectOnionKit
//
//  Created by Kevin Chin on 31/10/2026.
//

import XCTest
@testable import ConnectOnionKit

final class AgentBalanceTests: XCTestCase {
    private let address = "0x3d4017c3e843a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1"

    // MARK: Threshold

    func testThresholdIsOneDollar() {
        XCTAssertEqual(AgentBalance.lowThresholdUSD, 1.00)
    }

    // MARK: notice(for:)

    func testUnknownBalanceShowsNothing() {
        XCTAssertNil(AgentBalance.notice(for: nil))
    }

    func testHealthyBalanceShowsNothing() {
        XCTAssertNil(AgentBalance.notice(for: 25.34))
    }

    func testExactlyTheThresholdIsNotLow() {
        XCTAssertNil(AgentBalance.notice(for: 1.00))
    }

    func testJustAboveTheThresholdIsNotLow() {
        XCTAssertNil(AgentBalance.notice(for: 1.01))
    }

    func testJustBelowTheThresholdIsLow() {
        XCTAssertEqual(AgentBalance.notice(for: 0.99), .low(usd: 0.99))
    }

    func testOneCentIsLow() {
        XCTAssertEqual(AgentBalance.notice(for: 0.01), .low(usd: 0.01))
    }

    func testFractionOfACentBelowTheThresholdIsStillLow() {
        // The check uses the raw value, not the rounded text.
        XCTAssertEqual(AgentBalance.notice(for: 0.999), .low(usd: 0.999))
    }

    func testZeroIsEmpty() {
        XCTAssertEqual(AgentBalance.notice(for: 0), .empty)
    }

    func testNegativeIsEmpty() {
        XCTAssertEqual(AgentBalance.notice(for: -3.5), .empty)
    }

    func testNonFiniteBalancesShowNothing() {
        XCTAssertNil(AgentBalance.notice(for: .nan))
        XCTAssertNil(AgentBalance.notice(for: .infinity))
    }

    // MARK: message(for:)

    func testLowMessageShowsTwoDecimals() {
        XCTAssertEqual(AgentBalance.message(for: .low(usd: 0.42)), "Running low \u{2014} $0.42 left.")
        XCTAssertEqual(AgentBalance.message(for: .low(usd: 0.4)), "Running low \u{2014} $0.40 left.")
        XCTAssertEqual(AgentBalance.message(for: .low(usd: 0.05)), "Running low \u{2014} $0.05 left.")
    }

    func testLowMessageUsesADotWhateverTheDeviceLocale() {
        // Fixed formatting, so a device set to France or Germany still shows $0.42 and not $0,42.
        XCTAssertTrue(AgentBalance.message(for: .low(usd: 0.42)).contains("0.42"))
    }

    func testEmptyMessage() {
        XCTAssertEqual(
            AgentBalance.message(for: .empty),
            "This agent is out of credits and will stop responding."
        )
    }

    // MARK: topUpURL(agentAddress:)

    func testTopUpURLPointsAtThePurchasePageWithTheAddressAsKey() throws {
        let url = try XCTUnwrap(AgentBalance.topUpURL(agentAddress: address))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "o.openonion.ai")
        XCTAssertEqual(parts.path, "/purchase")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "key" })?.value, address)
    }

    func testTopUpURLEncodesUnsafeCharacters() throws {
        let url = try XCTUnwrap(AgentBalance.topUpURL(agentAddress: "a b&c"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "key" })?.value, "a b&c")
        XCTAssertEqual(parts.queryItems?.count, 1)
    }

    func testTopUpURLIsNilForAnEmptyAddress() {
        XCTAssertNil(AgentBalance.topUpURL(agentAddress: ""))
    }
}
