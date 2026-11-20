//
//  OIPPermissionModeTests.swift
//  ConnectOnionKit
//

import Foundation
import XCTest
@testable import ConnectOnionKit

final class OIPPermissionModeTests: XCTestCase {

    // Protocol value decoding
    func testReadOnlyProtocolValueDecodesCorrectly() {
        XCTAssertEqual(OIPPermissionMode(protocolValue: "read-only"), .readOnly)
    }

    func testAutoProtocolValueDecodesCorrectly() {
        XCTAssertEqual(OIPPermissionMode(protocolValue: "auto"), .auto)
    }

    func testFullAccessProtocolValueDecodesCorrectly() {
        XCTAssertEqual(OIPPermissionMode(protocolValue: "full-access"), .fullAccess)
    }

    func testUnknownProtocolValueIsPreserved() {
        let value = "future-mode-v9"
        let mode = OIPPermissionMode(protocolValue: value)
        XCTAssertEqual(mode, .unknown(value))
        XCTAssertEqual(mode.rawValue, value)
    }

    func testProtocolValueMatchingIsCaseSensitive() {
        XCTAssertEqual(OIPPermissionMode(protocolValue: "AUTO"), .unknown("AUTO"))
        XCTAssertEqual(OIPPermissionMode(protocolValue: "Read-Only"), .unknown("Read-Only"))
    }

    func testProtocolValueDoesNotTrimWhitespace() {
        XCTAssertEqual(OIPPermissionMode(protocolValue: " auto "), .unknown(" auto "))
    }

    // Raw values
    func testKnownModesReturnExactRawValues() {
        XCTAssertEqual(OIPPermissionMode.readOnly.rawValue, "read-only")
        XCTAssertEqual(OIPPermissionMode.auto.rawValue, "auto")
        XCTAssertEqual(OIPPermissionMode.fullAccess.rawValue, "full-access")
    }

    func testUnknownModeReturnsItsOriginalRawValue() {
        let originalValue = "future-permission"
        XCTAssertEqual(OIPPermissionMode.unknown(originalValue).rawValue, originalValue)
    }

    // Codable
    func testJSONDecoderDecodesAllKnownModes() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(OIPPermissionMode.self, from: Data(#""read-only""#.utf8)), .readOnly)
        XCTAssertEqual(try decoder.decode(OIPPermissionMode.self, from: Data(#""auto""#.utf8)), .auto)
        XCTAssertEqual(try decoder.decode(OIPPermissionMode.self, from: Data(#""full-access""#.utf8)), .fullAccess)
    }

    func testJSONEncoderEncodesKnownModesAsStrings() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(String(data: try encoder.encode(OIPPermissionMode.readOnly), encoding: .utf8), #""read-only""#)
        XCTAssertEqual(String(data: try encoder.encode(OIPPermissionMode.auto), encoding: .utf8), #""auto""#)
        XCTAssertEqual(String(data: try encoder.encode(OIPPermissionMode.fullAccess), encoding: .utf8), #""full-access""#)
    }

    func testUnknownModeSurvivesJSONRoundTrip() throws {
        let original = OIPPermissionMode.unknown("future-mode-v9")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OIPPermissionMode.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rawValue, "future-mode-v9")
    }

    func testJSONDecoderPreservesUnknownProtocolString() throws {
        let json = Data(#""new-server-mode""#.utf8)
        let decoded = try JSONDecoder().decode(OIPPermissionMode.self, from: json)
        XCTAssertEqual(decoded, .unknown("new-server-mode"))
    }

    func testJSONDecoderRejectsNonStringJSONValue() {
        let invalidValues = [
            Data("null".utf8),
            Data("123".utf8),
            Data("true".utf8),
            Data(#"{"mode":"auto"}"#.utf8),
            Data(#"["auto"]"#.utf8)
        ]

        for json in invalidValues {
            XCTAssertThrowsError(
                try JSONDecoder().decode(OIPPermissionMode.self, from: json),
                "Expected decoding to fail for JSON: \(String(data: json, encoding: .utf8) ?? "<non-UTF-8 data>")"
            )
        }
    }

    // Legacy stored values
    func testLegacyStoredValuesFallBackToAuto() {
        let legacyValues = ["safe", "plan", "accept_edits", "ulw"]
        for value in legacyValues {
            XCTAssertEqual(
                OIPPermissionMode(storedValue: value),
                .auto,
                "Expected legacy stored value '\(value)' to fall back to auto"
            )
        }
    }

    func testKnownProtocolValuesCanAlsoBeReadAsStoredValues() {
        XCTAssertEqual(OIPPermissionMode(storedValue: "read-only"), .readOnly)
        XCTAssertEqual(OIPPermissionMode(storedValue: "auto"), .auto)
        XCTAssertEqual(OIPPermissionMode(storedValue: "full-access"), .fullAccess)
    }

    func testUnknownStoredValueIsPreserved() {
        let value = "future-stored-mode"

        XCTAssertEqual(OIPPermissionMode(storedValue: value), .unknown(value))
    }

    // Permission mode state initialisation
    func testStateDefaultsToAutoWithNoPendingMode() {
        let state = OIPPermissionModeState()
        XCTAssertEqual(state.confirmedMode, .auto)
        XCTAssertNil(state.pendingMode)
    }

    func testStateCanBeInitialisedWithConfirmedAndPendingModes() {
        let state = OIPPermissionModeState(confirmedMode: .readOnly, pendingMode: .fullAccess)
        XCTAssertEqual(state.confirmedMode, .readOnly)
        XCTAssertEqual(state.pendingMode, .fullAccess)
    }

    // Pending request behaviour
    func testRequestDoesNotChangeConfirmedMode() {
        var state = OIPPermissionModeState(confirmedMode: .auto)
        state.request(.fullAccess)
        XCTAssertEqual(state.confirmedMode, .auto)
        XCTAssertEqual(state.pendingMode, .fullAccess)
    }

    func testEachKnownModeCanBeRequestedWithoutChangingConfirmation() {
        let requestedModes: [OIPPermissionMode] = [.readOnly, .auto, .fullAccess]
        for requestedMode in requestedModes {
            var state = OIPPermissionModeState(confirmedMode: .readOnly)
            state.request(requestedMode)
            XCTAssertEqual(state.confirmedMode, .readOnly, "Requesting \(requestedMode) must not change the confirmed mode")
            XCTAssertEqual(state.pendingMode, requestedMode)
        }
    }

    func testNewRequestReplacesPreviousPendingRequest() {
        var state = OIPPermissionModeState(confirmedMode: .readOnly)
        state.request(.auto)
        XCTAssertEqual(state.pendingMode, .auto)
        state.request(.fullAccess)
        XCTAssertEqual(state.confirmedMode, .readOnly)
        XCTAssertEqual(state.pendingMode, .fullAccess)
    }

    func testConfirmationUpdatesConfirmedModeAndClearsPendingMode() {
        var state = OIPPermissionModeState(confirmedMode: .auto)
        state.request(.fullAccess)
        state.confirm(.fullAccess)
        XCTAssertEqual(state.confirmedMode, .fullAccess)
        XCTAssertNil(state.pendingMode)
    }

    func testConfirmationCanUpdateModeWhenNoRequestIsPending() {
        var state = OIPPermissionModeState(confirmedMode: .auto)
        state.confirm(.readOnly)
        XCTAssertEqual(state.confirmedMode, .readOnly)
        XCTAssertNil(state.pendingMode)
    }

    func testConfirmationClearsPendingRequestEvenWhenConfirmedModeDiffers() {
        var state = OIPPermissionModeState(confirmedMode: .auto)
        // The server may report a mode different from the one requested.
        state.request(.fullAccess)
        state.confirm(.readOnly)
        XCTAssertEqual(state.confirmedMode, .readOnly)
        XCTAssertNil(state.pendingMode)
    }

    func testUnknownModeCanBeHeldInPermissionModeState() {
        let unknownMode = OIPPermissionMode.unknown("future-mode")
        var state = OIPPermissionModeState(confirmedMode: .auto)
        state.request(unknownMode)
        XCTAssertEqual(state.confirmedMode, .auto)
        XCTAssertEqual(state.pendingMode, unknownMode)
        state.confirm(unknownMode)
        XCTAssertEqual(state.confirmedMode, unknownMode)
        XCTAssertNil(state.pendingMode)
    }
}
