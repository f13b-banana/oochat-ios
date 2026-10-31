import Foundation
import XCTest
@testable import ConnectOnionKit

final class CanonicalJSONTests: XCTestCase {
    func testCanonicalObjectOrdering() {
        let first: [String: JSONValue] = [
            "a": .number(1),
            "b": .number(2)
        ]

        let second: [String: JSONValue] = [
            "b": .number(2),
            "a": .number(1)
        ]

        XCTAssertEqual(
            CanonicalJSON.data(from: first),
            CanonicalJSON.data(from: second)
        )
    }

    // from MockHostedAgentTests.swift
    func testCanonicalJSONMatchesPythonUnicodeEscaping() {
        let value: JSONValue = .object([
            "prompt": .string("执行 tree café 🧅")
        ])

        XCTAssertEqual(
            CanonicalJSON.string(from: value),
            #"{"prompt":"\u6267\u884c tree caf\u00e9 \ud83e\uddc5"}"#
        )
    }

    func testLargeNumberDoesNotTrap() {
        XCTAssertEqual(CanonicalJSON.string(from: .number(1e20)), "1e+20")
    }

    // numbers
    func testWholeNumbers() {
        XCTAssertEqual(CanonicalJSON.string(from: .number(0)), "0")
        XCTAssertEqual(CanonicalJSON.string(from: .number(-0.0)), "0")
        XCTAssertEqual(CanonicalJSON.string(from: .number(-5)), "-5")
        XCTAssertEqual(CanonicalJSON.string(from: .number(123_456_789)), "123456789")
        XCTAssertEqual(CanonicalJSON.string(from: .number(1_234_567_890)), "1234567890")
    }

    func testFractions() {
        XCTAssertEqual(CanonicalJSON.string(from: .number(1.5)), "1.5")
        XCTAssertEqual(CanonicalJSON.string(from: .number(0.1)), "0.1")
        XCTAssertEqual(CanonicalJSON.string(from: .number(1e-7)), "1e-07")
        XCTAssertEqual(CanonicalJSON.string(from: .number(123_456_789.15)), "123456789.15")
    }

    func testLiterals() {
        XCTAssertEqual(CanonicalJSON.string(from: .bool(true)), "true")
        XCTAssertEqual(CanonicalJSON.string(from: .bool(false)), "false")
        XCTAssertEqual(CanonicalJSON.string(from: .null), "null")
        XCTAssertEqual(CanonicalJSON.string(from: .string("")), #""""#)
    }

    func testJSONEncoder() throws {
        let timestamp = JSONValue.number(123_456_789)

        let encoded = String(data: try JSONEncoder().encode([timestamp]), encoding: .utf8)

        XCTAssertEqual(encoded, "[" + CanonicalJSON.string(from: timestamp) + "]")
    }
}
