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
                balanceUSD: 25.34,
                providerStation: nil
            ))
        )
    }

    func testAgentProfileMinimalFrameGetsDefaults() {
        XCTAssertEqual(
            OIPServerFrame.decode(frame("AGENT_PROFILE")),
            .agentProfile(OIPAgentProfile(
                sessionID: nil, name: nil, address: nil, model: nil, tools: [], skills: [], balanceUSD: nil, providerStation: nil
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
    // MARK: DASHBOARD_SNAPSHOT

    func testDashboardSnapshotDecodesSpecFixture() throws {
        XCTAssertEqual(
            try decode("DASHBOARD_SNAPSHOT"),
            .dashboardSnapshot(OIPDashboardSnapshot(
                html: "<!DOCTYPE html><html><body>Hi</body></html>",
                sessionID: sessionID
            ))
        )
    }

    func testDashboardSnapshotWithoutSessionID() throws {
        XCTAssertEqual(
            try decode("DASHBOARD_SNAPSHOT.no_session"),
            .dashboardSnapshot(OIPDashboardSnapshot(
                html: "<!DOCTYPE html><html><body>Hi</body></html>",
                sessionID: nil
            ))
        )
    }

    func testDashboardSnapshotOverOneMiBKeepsWholeHTML() throws {
        let input = try fixture("DASHBOARD_SNAPSHOT.large")
        let expected = try XCTUnwrap(input["html"]?.stringValue)
        XCTAssertGreaterThan(expected.utf8.count, 1_048_576)
        guard case .dashboardSnapshot(let snapshot) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .dashboardSnapshot")
        }
        XCTAssertEqual(snapshot.html, expected)
        XCTAssertEqual(snapshot.sessionID, sessionID)
    }

    func testDashboardSnapshotMissingHTMLIsUnknown() throws {
        let input = try fixture("DASHBOARD_SNAPSHOT.malformed")
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "DASHBOARD_SNAPSHOT", body: input))
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

    // MARK: Provider frames

    func testProviderInvocationDecodesCatalogFixture() throws {
        XCTAssertEqual(
            try decode("provider_invocation"),
            .providerInvocation(OIPProviderInvocation(
                invocationID: "codex:call-7",
                parentToolCallID: "call-7",
                provider: .codex,
                status: .running,
                stateRevision: 1,
                taskTitle: "Build and verify the requested C program",
                currentSummary: "Working in the selected workspace",
                resultSummary: nil,
                errorSummary: nil,
                workroomID: "codex:call-7",
                continuationOf: nil
            ))
        )
    }

    func testProviderInvocationTerminalFixture() throws {
        guard case .providerInvocation(let invocation) = try decode("provider_invocation.terminal") else {
            return XCTFail("expected .providerInvocation")
        }
        XCTAssertEqual(invocation.status, .cancelled)
        XCTAssertEqual(invocation.stateRevision, 3)
        XCTAssertEqual(invocation.resultSummary, "The provider stopped")
        XCTAssertNil(invocation.taskTitle)
    }

    func testProviderInvocationWithUnknownProviderIsUnknown() throws {
        var input = try fixture("provider_invocation")
        input["provider"] = .string("gemini")
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "provider_invocation", body: input))
    }

    func testProviderActivityDecodesCatalogFixture() throws {
        XCTAssertEqual(
            try decode("provider_activity"),
            .providerActivity(OIPProviderActivity(
                invocationID: "codex:call-7",
                parentToolCallID: "call-7",
                provider: .codex,
                activityID: "create-sort",
                sequence: 2,
                kind: .fileChange,
                status: .completed,
                title: "Update workspace files",
                summary: "Workspace files updated",
                files: ["sort.c"]
            ))
        )
    }

    func testProviderMessageDecodesCatalogFixture() throws {
        XCTAssertEqual(
            try decode("provider_message"),
            .providerMessage(OIPProviderMessage(
                invocationID: "codex:call-7",
                parentToolCallID: "call-7",
                provider: .codex,
                messageID: "assistant:plan",
                role: .assistant,
                text: "I’ll create the isolated project and verify it independently."
            ))
        )
    }

    // MARK: Provider acks

    private func ack(_ name: String) throws -> OIPProviderAck {
        let decoded = try decode(name)
        switch decoded {
        case .providerInterruptAck(let ack), .providerInputAck(let ack), .providerPermissionAck(let ack):
            return ack
        default:
            XCTFail("\(name) did not decode to an invocation ack")
            throw CocoaError(.coderInvalidValue)
        }
    }

    func testInterruptAckDecodesAcceptedFixture() throws {
        guard case .providerInterruptAck(let ack) = try decode("PROVIDER_INTERRUPT_ACK.accepted") else {
            return XCTFail("expected .providerInterruptAck")
        }
        XCTAssertEqual(
            ack,
            OIPProviderAck(
                requestID: "interrupt-1", invocationID: "codex:call-7", accepted: true,
                stateRevision: 2, reason: nil, providerPermission: nil
            )
        )
    }

    func testInputAckDecodesAcceptedFixture() throws {
        guard case .providerInputAck(let ack) = try decode("PROVIDER_INPUT_ACK") else {
            return XCTFail("expected .providerInputAck")
        }
        XCTAssertTrue(ack.accepted)
        XCTAssertEqual(ack.stateRevision, 1)
        XCTAssertNil(ack.reason)
    }

    func testPermissionAckKeepsProviderPermissionRaw() throws {
        guard case .providerPermissionAck(let ack) = try decode("PROVIDER_PERMISSION_ACK.accepted") else {
            return XCTFail("expected .providerPermissionAck")
        }
        XCTAssertTrue(ack.accepted)
        XCTAssertEqual(ack.stateRevision, 2)
        XCTAssertEqual(ack.providerPermission?.objectValue?["effectiveRevision"], .number(2))
    }

    func testEveryDocumentedInvocationAckReasonDecodes() throws {
        let reasons: [(String, [String])] = [
            ("PROVIDER_INTERRUPT_ACK", [
                "not_active", "invalid_request", "invalid_revision", "state_changed", "state_unconfirmed"
            ]),
            ("PROVIDER_INPUT_ACK", [
                "invalid_request", "invalid_revision", "not_active", "unsupported_provider", "state_changed",
                "state_unconfirmed", "provider_start_failed", "terminal_owns_session"
            ]),
            ("PROVIDER_PERMISSION_ACK", [
                "invalid_request", "invalid_revision", "not_owner", "operator_required", "not_found",
                "unsupported_option", "ceiling_denied", "confirmation_required", "unavailable"
            ])
        ]
        for (type, list) in reasons {
            for reason in list {
                let decoded = try ack("\(type).\(reason)")
                XCTAssertFalse(decoded.accepted, "\(type).\(reason)")
                XCTAssertEqual(decoded.reason, reason)
                XCTAssertEqual(decoded.stateRevision, 2)
            }
        }
    }

    func testPermissionAckStaleRevisionFixtureDecodes() throws {
        let decoded = try ack("PROVIDER_PERMISSION_ACK")
        XCTAssertFalse(decoded.accepted)
        XCTAssertEqual(decoded.reason, "stale_revision")
        XCTAssertNil(decoded.stateRevision)
    }

    func testAckWithAnUnknownReasonStillDecodes() throws {
        var input = try fixture("PROVIDER_INPUT_ACK.not_active")
        input["reason"] = .string("brand_new_reason")
        guard case .providerInputAck(let ack) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .providerInputAck")
        }
        XCTAssertFalse(ack.accepted)
        XCTAssertEqual(ack.reason, "brand_new_reason")
    }

    func testAckWithoutAcceptedIsUnknown() throws {
        var input = try fixture("PROVIDER_INTERRUPT_ACK.accepted")
        input["accepted"] = nil
        XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: "PROVIDER_INTERRUPT_ACK", body: input))
    }

    func testAckKeepsAnEmptyRequestIDAndDropsABadRevision() throws {
        var input = try fixture("PROVIDER_INTERRUPT_ACK.invalid_request")
        input["requestId"] = .string("")
        input["invocationId"] = .null
        input["stateRevision"] = .number(0)
        guard case .providerInterruptAck(let ack) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .providerInterruptAck")
        }
        XCTAssertEqual(ack.requestID, "")
        XCTAssertNil(ack.invocationID)
        XCTAssertNil(ack.stateRevision)
    }

    func testStationAttachAckDecodesAcceptedAndRejections() throws {
        XCTAssertEqual(
            try decode("PROVIDER_STATION_ATTACH_ACK"),
            .providerStationAttachAck(OIPProviderStationAttachAck(
                requestID: "attach-1", accepted: true, sessionID: "station-session", reason: nil
            ))
        )
        for reason in ["invalid_request", "invalid_pairing_code"] {
            guard case .providerStationAttachAck(let ack) = try decode("PROVIDER_STATION_ATTACH_ACK.\(reason)") else {
                return XCTFail("expected .providerStationAttachAck")
            }
            XCTAssertFalse(ack.accepted)
            XCTAssertNil(ack.sessionID)
            XCTAssertEqual(ack.reason, reason)
        }
    }

    func testControlAckDecodesAcceptedAndRejections() throws {
        XCTAssertEqual(
            try decode("PROVIDER_CONTROL_ACK"),
            .providerControlAck(OIPProviderControlAck(
                requestID: "control-1", action: "take", accepted: true, stateRevision: 3, reason: nil
            ))
        )
        let reasons = ["invalid_request", "stale_or_unowned", "not_ready", "handover_timeout", "provider_busy"]
        for reason in reasons {
            guard case .providerControlAck(let ack) = try decode("PROVIDER_CONTROL_ACK.\(reason)") else {
                return XCTFail("expected .providerControlAck")
            }
            XCTAssertFalse(ack.accepted)
            XCTAssertNil(ack.stateRevision)
            XCTAssertEqual(ack.reason, reason)
        }
    }

    func testControlAckWithoutAnActionStillDecodes() throws {
        var input = try fixture("PROVIDER_CONTROL_ACK")
        input["action"] = nil
        guard case .providerControlAck(let ack) = OIPServerFrame.decode(input) else {
            return XCTFail("expected .providerControlAck")
        }
        XCTAssertTrue(ack.accepted)
        XCTAssertNil(ack.action)
        XCTAssertEqual(ack.stateRevision, 3)
    }

    func testStationAndControlAcksNeedRequestID() throws {
        for name in ["PROVIDER_STATION_ATTACH_ACK", "PROVIDER_CONTROL_ACK"] {
            var input = try fixture(name)
            input["request_id"] = nil
            input["requestId"] = nil
            XCTAssertEqual(OIPServerFrame.decode(input), .unknown(type: name, body: input))
        }
    }

    func testStationAndControlAcksAcceptEitherSpellingOfTheRequestID() throws {
        for name in ["PROVIDER_STATION_ATTACH_ACK", "PROVIDER_CONTROL_ACK"] {
            var input = try fixture(name)
            input["requestId"] = input["request_id"]
            input["request_id"] = nil
            if case .unknown = OIPServerFrame.decode(input) {
                XCTFail("\(name) with requestId only did not decode")
            }
        }
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
            OIPFrameType.dashboardSnapshot,
            OIPFrameType.ping,
            OIPFrameType.providerInvocation,
            OIPFrameType.providerActivity,
            OIPFrameType.providerMessage,
            OIPFrameType.providerArtifact,
            OIPFrameType.providerSession,
            OIPFrameType.providerInterruptAck,
            OIPFrameType.providerInputAck,
            OIPFrameType.providerPermissionAck,
            OIPFrameType.providerStationAttachAck,
            OIPFrameType.providerControlAck
        ]).union(OIPServerFrame.streamEventTypes)

        for file in files {
            let input = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
            let type = try XCTUnwrap(input["type"]?.stringValue, "\(file.lastPathComponent) has no type")
            let decoded = OIPServerFrame.decode(input)
            // These two are handled types whose fixture is deliberately malformed: SESSION_STATUS.request is
            // the client's own frame and has no `status`; DASHBOARD_SNAPSHOT.malformed has no `html`.
            let malformed: Set<String> = ["SESSION_STATUS.request.json", "DASHBOARD_SNAPSHOT.malformed.json"]
            let expectUnknown = !handled.contains(type) || malformed.contains(file.lastPathComponent)
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
