//
//  OIPServerFramesTests.swift
//  ConnectOnionKit
//
//

import Foundation
import XCTest
@testable import ConnectOnionKit

final class OIPServerFrameTests: XCTestCase {

    // MARK: Helpers

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/frames"),
            "Missing fixture \(name).json"
        )
    }

    private func fixture(_ name: String) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: fixtureURL(name)))
    }

    private func decode(_ name: String) throws -> OIPServerFrame {
        OIPServerFrame.decode(try fixture(name))
    }

    private func frame(_ type: String, _ fields: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var result = fields
        result["type"] = .string(type)
        return result
    }

    private let sessionID = "550e8400-e29b-41d4-a716-446655440000"

    // MARK: CONNECTED

    func testConnectedDecodesSpecFixture() throws {
        guard case .connected(let connected) = try decode("CONNECTED") else {
            return XCTFail("expected .connected")
        }
        XCTAssertEqual(connected.status, "new")
        XCTAssertEqual(connected.sessionID, sessionID)
        XCTAssertTrue(connected.serverNewer)
        XCTAssertEqual(connected.hostProtocol?.name, "oip")
        XCTAssertEqual(connected.hostProtocol?.version, "0.1")
        XCTAssertEqual(connected.sessionModes?.currentMode, .auto)
        XCTAssertNil(connected.sessionModes?.turnsLeft)
        XCTAssertEqual(
            connected.sessionModes?.availableModes,
            [
                OIPModeOption(id: .readOnly, name: "Read only"),
                OIPModeOption(id: .auto, name: "Auto"),
                OIPModeOption(id: .fullAccess, name: "Full access")
            ]
        )
        XCTAssertEqual(connected.session, ["messages": .array([])])
        XCTAssertEqual(connected.chatItems, [])
    }

    func testConnectedIndexSocketHasNoSessionID() throws {
        guard case .connected(let connected) = try decode("CONNECTED.index") else {
            return XCTFail("expected .connected")
        }
        XCTAssertEqual(connected.status, "index")
        XCTAssertNil(connected.sessionID)
        XCTAssertNil(connected.sessionModes)
        XCTAssertFalse(connected.serverNewer)
        XCTAssertEqual(connected.hostProtocol?.websocketPath, "/ws")
    }

    func testConnectedMissingStatusIsUnknown() {
        let input = frame("CONNECTED", ["session_id": .string(sessionID)])
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "CONNECTED", body: input))
    }

    // MARK: ERROR

    func testErrorPlainMessage() throws {
        XCTAssertEqual(
            try decode("ERROR"), .error(OIPServerError(code: nil, message: "Something went wrong", reason: nil, requestID: nil)))
    }

    func testErrorStaleAnswerHasStringCodeAndNoMessage() throws {
        guard case .error(let error) = try decode("ERROR.stale_answer") else {
            return XCTFail("expected .error")
        }

        XCTAssertEqual(error.code, .string("STALE_ANSWER"))
        XCTAssertNil(error.message)
        XCTAssertEqual(error.reason, "stale")
        XCTAssertEqual(error.requestID, "ev-appr-0")
    }

    func testErrorIntegerCodeIsPreserved() throws {
        guard case .error(let error) = try decode("ERROR.incompatible_version") else {
            return XCTFail("expected .error")
        }

        XCTAssertEqual(error.code, .int(-32010))
        XCTAssertEqual(error.message, "Unsupported OIP protocol")
    }

    func testErrorIntegerCodeCanBeDecodedWithoutOtherFields() {
        let input = frame("ERROR", [
            "code": .number(1234)
        ])

        XCTAssertEqual(
            OIPServerFrame.decode(input), .error(OIPServerError(code: .int(1234), message: nil, reason: nil, requestID: nil)))
    }

    func testErrorWithoutCodeCanStillDecodeMessageAndReason() {
        let input = frame("ERROR", [
            "message": .string("Request could not be completed"),
            "reason": .string("stale")
        ])

        XCTAssertEqual(
            OIPServerFrame.decode(input), .error(OIPServerError(code: nil, message: "Request could not be completed",
                                                                reason: "stale", requestID: nil)))
    }

    func testErrorMissingAllOptionalFieldsStillDecodes() {
        let input = frame("ERROR")

        XCTAssertEqual(
            OIPServerFrame.decode(input), .error(OIPServerError(code: nil, message: nil, reason: nil, requestID: nil)))
    }

    func testErrorUnknownStringCodeIsPreserved() {
        let input = frame("ERROR", [
            "code": .string("SOME_FUTURE_ERROR"),
            "message": .string("An unknown error occurred")
        ])

        guard case .error(let error) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .error")
        }

        XCTAssertEqual(error.code, .string("SOME_FUTURE_ERROR"))
        XCTAssertEqual(error.message, "An unknown error occurred")
    }

    // MARK: OUTPUT

    func testOutputDecodesSpecFixture() throws {
        guard case .output(let output) = try decode("OUTPUT") else {
            return XCTFail("expected .output")
        }
        XCTAssertEqual(output.result, "Hola")
        XCTAssertEqual(output.sessionID, sessionID)
        XCTAssertEqual(output.durationMS, 1250)
        XCTAssertEqual(output.session?["turn"], .number(2))
    }

    func testOutputWithoutSessionIDOrSession() {
        let input = frame("OUTPUT", ["result": .string("Done.")])
        XCTAssertEqual(
            OIPServerFrame.decode(input),
            .output(OIPOutput(result: "Done.", sessionID: nil, durationMS: nil, session: nil))
        )
    }

    func testOutputMissingResultIsUnknown() {
        let input = frame("OUTPUT")
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "OUTPUT", body: input))
    }

    // MARK: AGENT_PROFILE

    func testAgentProfileDecodesSpecFixture() throws {
        XCTAssertEqual(
            try decode("AGENT_PROFILE"),
            .agentProfile(OIPAgentProfile(
                sessionID: sessionID,
                name: "my-agent",
                address: "0x3d4017c3e843a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1",
                model: "co/gemini-3.8-flash",
                tools: ["search", "shell"],
                skills: [
                    OIPAgentSkill(name: "co-browser", description: "drive a browser", location: "project"),
                    OIPAgentSkill(name: "my-notes", description: "personal", location: "user")
                ],
                balanceUSD: 25.34
            ))
        )
    }

    func testAgentProfileMinimalFrameGetsDefaults() {
        XCTAssertEqual(
            OIPServerFrame.decode(frame("AGENT_PROFILE")),
            .agentProfile(OIPAgentProfile(
                sessionID: nil, name: nil, address: nil, model: nil, tools: [], skills: [], balanceUSD: nil
            ))
        )
    }

    func testAgentProfileToleratesStringSkillsAndObjectTools() {
        let input = frame("AGENT_PROFILE", [
            "tools": .array([.object(["name": .string("bash")])]),
            "skills": .array([.string("review")])
        ])
        guard case .agentProfile(let profile) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .agentProfile")
        }
        XCTAssertEqual(profile.tools, ["bash"])
        XCTAssertEqual(profile.skills, [OIPAgentSkill(name: "review", description: nil, location: nil)])
    }

    // MARK: SESSION_STATUS

    func testSessionStatusConnected() throws {
        XCTAssertEqual(try decode("SESSION_STATUS"), .sessionStatus(sessionID: sessionID, status: "connected"))
    }

    func testSessionStatusRunning() throws {
        XCTAssertEqual(try decode("SESSION_STATUS.running"), .sessionStatus(sessionID: sessionID, status: "running"))
    }

    func testSessionStatusNotFound() throws {
        XCTAssertEqual(try decode("SESSION_STATUS.not_found"), .sessionStatus(sessionID: sessionID, status: "not_found"))
    }

    func testSessionStatusRequestShapeIsUnknown() throws {
        let input = try fixture("SESSION_STATUS.request")
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "SESSION_STATUS", body: input))
    }

    // MARK: mode_changed

    func testModeChangedAuto() throws {
        XCTAssertEqual(try decode("mode_changed"), .modeChanged(mode: .auto, turnsLeft: nil))
    }

    func testModeChangedFullAccessWithTurnsLeft() throws {
        XCTAssertEqual(try decode("mode_changed.full_access"), .modeChanged(mode: .fullAccess, turnsLeft: 5))
    }

    func testModeChangedUnknownModeKeepsRawString() {
        let input = frame("mode_changed", ["mode": .string("turbo")])
        guard case .modeChanged(let mode, let turnsLeft) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .modeChanged")
        }
        XCTAssertEqual(mode, .unknown("turbo"))
        XCTAssertEqual(mode.rawValue, "turbo")
        XCTAssertNil(turnsLeft)
    }

    func testModeChangedMissingModeIsUnknown() {
        let input = frame("mode_changed", ["turns_left": .number(3)])
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "mode_changed", body: input))
    }

    // MARK: EXEC_RESULT

    func testExecResultSuccess() throws {
        XCTAssertEqual(
            try decode("EXEC_RESULT"),
            .execResult(OIPExecResult(
                execID: "7c2a91d0", tool: "bash", status: "success", result: "ok", error: nil, durationMS: 42
            ))
        )
        guard case .execResult(let result) = try decode("EXEC_RESULT") else {
            return XCTFail("expected .execResult")
        }
        XCTAssertTrue(result.isSuccess)
    }

    func testExecResultError() throws {
        guard case .execResult(let result) = try decode("EXEC_RESULT.error") else {
            return XCTFail("expected .execResult")
        }
        XCTAssertEqual(result.execID, "7c2a91d1")
        XCTAssertFalse(result.isSuccess)
        XCTAssertNil(result.result)
        XCTAssertEqual(result.error, "tool not whitelisted")
    }

    func testExecResultMissingExecIDIsUnknown() {
        let input = frame("EXEC_RESULT", ["status": .string("success")])
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "EXEC_RESULT", body: input))
    }

    // MARK: ONBOARD_REQUIRED
    func testOnboardRequiredDecodesSpecFixture() throws {
        XCTAssertEqual(
            try decode("ONBOARD_REQUIRED"),
            .onboardRequired(
                OIPOnboardRequired(
                    identity: "0xc0ffee11c0ffee11c0ffee11c0ffee11c0ffee11c0ffee11c0ffee11c0ffee11",
                    methods: ["invite_code", "payment"],
                    paymentAmount: 10,
                    paymentAddress: "0x3d4017c3e843a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1"
                )
            )
        )
    }

    func testOnboardRequiredInviteCodeOnlyHasNoPayment() {
        let input = frame(
            "ONBOARD_REQUIRED",
            [
                "methods": .array([.string("invite_code")])
            ]
        )

        XCTAssertEqual(
            OIPServerFrame.decode(input),
            .onboardRequired(
                OIPOnboardRequired(
                    identity: nil,
                    methods: ["invite_code"],
                    paymentAmount: nil,
                    paymentAddress: nil
                )
            )
        )
    }

    func testOnboardRequiredMinimalFrameGetsDefaults() {
        XCTAssertEqual(
            OIPServerFrame.decode(frame("ONBOARD_REQUIRED")),
            .onboardRequired(
                OIPOnboardRequired(
                    identity: nil,
                    methods: [],
                    paymentAmount: nil,
                    paymentAddress: nil
                )
            )
        )
    }
    // MARK: PING

    func testPingDecodesSpecFixture() throws {
        XCTAssertEqual(try decode("PING"), .ping)
    }

    func testPingIgnoresExtraFields() {
        XCTAssertEqual(OIPServerFrame.decode(frame("PING", ["ts": .number(1)])), .ping)
    }

    func testPingTypeMatchIsCaseSensitive() {
        let input = frame("ping")
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "ping", body: input))
    }

    // MARK: Stream events

    func testEventFramesDecodeAsEvents() throws {
        let names = [
            "plan", "thinking", "tool_call", "tool_result", "ask_user", "approval_needed",
            "compact", "user_message", "user_input", "RUNTIME_INPUT_ACK", "ONBOARD_SUCCESS"
        ]
        for name in names {
            let input = try fixture(name)
            XCTAssertEqual(
                OIPServerFrame.decode(input),
                .event(type: name, id: input["id"]?.stringValue, body: input),
                "\(name) should decode as .event"
            )
        }
    }

    func testPlanEventKeepsEntries() throws {
        guard case .event(_, _, let body) = try decode("plan") else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(body["entries"]?.arrayValue?.count, 2)
    }

    func testToolCallEventKeepsIDAndBody() throws {
        let input = try fixture("tool_call")
        guard case .event(let type, let id, let body) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(type, "tool_call")
        XCTAssertEqual(id, "ev-tc-1")
        XCTAssertEqual(body, input)
        XCTAssertEqual(body["args"]?.objectValue?["command"], .string("ls"))
    }

    func testThinkingEventHasNoID() throws {
        XCTAssertEqual(try decode("thinking"), .event(type: "thinking", id: nil, body: try fixture("thinking")))
    }

    // MARK: Unknown

    func testEveryFixtureDecodesAndOnlyHandledTypesAreTyped() throws {
        let directory = try XCTUnwrap(
            Bundle.module.url(forResource: "frames", withExtension: nil, subdirectory: "Fixtures")
        )
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThan(files.count, 60)

        let handled = Set([
            OIPFrameType.connected,
            OIPFrameType.error,
            OIPFrameType.output,
            OIPFrameType.agentProfile,
            OIPFrameType.sessionStatus,
            OIPFrameType.modeChanged,
            OIPFrameType.execResult,
            OIPFrameType.onboardRequired,
            OIPFrameType.ping
        ]).union(OIPServerFrame.streamEventTypes)

        for file in files {
            let input = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
            let type = try XCTUnwrap(input["type"]?.stringValue, "\(file.lastPathComponent) has no type")
            let decoded = OIPServerFrame.decode(input)
            // SESSION_STATUS.request is the client's own frame and has no `status`.
            let expectUnknown = !handled.contains(type) || file.lastPathComponent == "SESSION_STATUS.request.json"
            if expectUnknown {
                XCTAssertEqual(decoded, .unknown(type: type, body: input), file.lastPathComponent)
            } else if case .unknown = decoded {
                XCTFail("\(file.lastPathComponent) should decode to a typed frame")
            }
        }
    }

    func testMissingTypeIsUnknownWithNilType() {
        let input: [String: JSONValue] = ["result": .string("orphan")]
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: nil, body: input))
    }

    func testNonStringTypeIsUnknownWithNilType() {
        let input: [String: JSONValue] = ["type": .number(7)]
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: nil, body: input))
    }
}
