//
//  OIPProtocolConstants.swift
//  ConnectOnionKit
//

public enum OIP {
    public static let name = "oip"
    public static let version = "0.1"
    public static let minVersion = "0.1"
    public static let maxVersion = "0.1"

    public static let descriptor: [String: JSONValue] = [
        "name": .string(name),
        "version": .string(version),
        "min_version": .string(minVersion),
        "max_version": .string(maxVersion)
    ]

    /// The extension that lets a client pair with a Claude Station and take Control of it.
    public static let sessionSyncExtension = "session-sync"
    public static let sessionSyncVersion = "0.1"
}

// OIP error codes
public enum OIPErrorCode {
    public static let incompatibleVersion = -32010
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let staleAnswer = "STALE_ANSWER"
    /// The host is a Claude Station: it answers an outer INPUT or EXEC with this code.
    public static let providerStationOnly = "provider_station_only"
}
// Definitions for OIP Protocol frames
public enum OIPFrameType {
    // Client → server
    public static let connect = "CONNECT"
    public static let input = "INPUT"
    public static let exec = "EXEC"
    public static let pong = "PONG"
    public static let askUserResponse = "ASK_USER_RESPONSE"
    public static let approvalResponse = "APPROVAL_RESPONSE"
    public static let interrupt = "INTERRUPT"
    public static let modeChange = "mode_change"
    public static let sessionSync = "SESSION_SYNC"
    public static let sessionGet = "SESSION_GET"
    public static let sessionWatch = "SESSION_WATCH"
    public static let sessionUpdate = "SESSION_UPDATE"
    public static let onboardSubmit = "ONBOARD_SUBMIT"
    public static let seal = "SEAL"
    public static let proxyAttach = "PROXY_ATTACH"
    public static let providerInterrupt = "PROVIDER_INTERRUPT"
    public static let providerPermissionChange = "PROVIDER_PERMISSION_CHANGE"
    public static let providerInput = "PROVIDER_INPUT"
    public static let providerStationAttach = "PROVIDER_STATION_ATTACH"
    public static let providerControl = "PROVIDER_CONTROL"
    public static let wikiRead = "WIKI_READ"
    public static let adminPromote = "ADMIN_PROMOTE"
    public static let adminDemote = "ADMIN_DEMOTE"
    public static let adminBlock = "ADMIN_BLOCK"
    public static let adminUnblock = "ADMIN_UNBLOCK"

    // Server → client
    public static let connected = "CONNECTED"
    public static let output = "OUTPUT"
    public static let plan = "plan"
    public static let execResult = "EXEC_RESULT"
    public static let ping = "PING"
    public static let thinking = "thinking"
    public static let toolCall = "tool_call"
    public static let toolResult = "tool_result"
    public static let askUser = "ask_user"
    public static let approvalNeeded = "approval_needed"
    public static let compact = "compact"
    public static let userMessage = "user_message"
    public static let userInput = "user_input"
    public static let agentProfile = "AGENT_PROFILE"
    public static let dashboardSnapshot = "DASHBOARD_SNAPSHOT"
    public static let wikiResult = "WIKI_RESULT"
    public static let controlCenterApp = "CONTROL_CENTER_APP"
    public static let runtimeInputAck = "RUNTIME_INPUT_ACK"
    public static let onboardRequired = "ONBOARD_REQUIRED"
    public static let onboardSuccess = "ONBOARD_SUCCESS"
    public static let adminResult = "ADMIN_RESULT"
    public static let error = "ERROR"
    public static let proxyAttached = "PROXY_ATTACHED"
    public static let sealedOk = "SEALED_OK"
    public static let sessionSyncResult = "SESSION_SYNC_RESULT"
    public static let sessionSnapshot = "SESSION_SNAPSHOT"
    public static let sessionNotModified = "SESSION_NOT_MODIFIED"
    public static let sessionWatched = "SESSION_WATCHED"
    public static let sessionChanged = "SESSION_CHANGED"
    public static let providerInterruptAck = "PROVIDER_INTERRUPT_ACK"
    public static let providerPermissionAck = "PROVIDER_PERMISSION_ACK"
    public static let providerInputAck = "PROVIDER_INPUT_ACK"
    public static let providerStationAttachAck = "PROVIDER_STATION_ATTACH_ACK"
    public static let providerControlAck = "PROVIDER_CONTROL_ACK"
    public static let modeChanged = "mode_changed"
    public static let providerInvocation = "provider_invocation"
    public static let providerActivity = "provider_activity"
    public static let providerMessage = "provider_message"
    public static let providerArtifact = "provider_artifact"
    public static let providerSession = "provider_session"

    // Both directions
    public static let sessionStatus = "SESSION_STATUS"
    public static let sealed = "SEALED"
    public static let proxyStream = "PROXY_STREAM"

}
