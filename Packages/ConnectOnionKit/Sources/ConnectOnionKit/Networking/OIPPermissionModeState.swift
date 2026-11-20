//
//  OIPPermissionModeState.swift
//  ConnectOnionKit
//

// This tracks the server-confirmed mode and any outstanding mode requests being made

public struct OIPPermissionModeState: Equatable, Sendable {

    // defining the confirmed server mode and any pending mode requests
    public private(set) var confirmedMode: OIPPermissionMode
    public private(set) var pendingMode: OIPPermissionMode?

    public init(confirmedMode: OIPPermissionMode = .auto, pendingMode: OIPPermissionMode? = nil) {
        self.confirmedMode = confirmedMode
        self.pendingMode = pendingMode
    }

    // Records a request without treating it as confirmed.
    public mutating func request(_ mode: OIPPermissionMode) {
        pendingMode = mode
    }

    // Applies the mode reported by a server mode_changed event.
    public mutating func confirm(_ mode: OIPPermissionMode) {
        confirmedMode = mode
        pendingMode = nil
    }
}
