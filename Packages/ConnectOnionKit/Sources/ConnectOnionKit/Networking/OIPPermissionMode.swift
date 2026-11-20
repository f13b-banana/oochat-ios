//
//  OIPPermissionMode.swift
//  ConnectOnionKit
//

import Foundation

// Permission modes defined by the OIP 0.2 protocol

public enum OIPPermissionMode: Equatable, Hashable, Sendable {

    // The four permission modes defined by specification
    case readOnly
    case auto
    case fullAccess

    // Add another case to handle unknown permission nodes being processed
    case unknown(String)

    // Based on the case, return the string representation of each mode
    public var rawValue: String {
        switch self {
        case .readOnly:
            return "read-only"
        case .auto:
            return "auto"
        case .fullAccess:
            return "full-access"
        case .unknown(let value):
            return value
        }
    }

    // Decode a value received based on the defined 0.2 protocol
    public init(protocolValue: String) {
        switch protocolValue {
        case "read-only":
            self = .readOnly
        case "auto":
            self = .auto
        case "full-access":
            self = .fullAccess
        // otherwise default to an unknown value
        default:
            self = .unknown(protocolValue)
        }
    }

    // From the provided specification, we have to account for older version values
    // iOS will currently send the following:
    // "safe", "plan", "accept_edits", "ulw" (cases came from existing iOS codebase) will go to auto mode, anything else will default to unknown value
    public init(storedValue: String) {
        switch storedValue {
        case "safe", "plan", "accept_edits", "ulw":
            self = .auto
        default:
            self = OIPPermissionMode(protocolValue: storedValue)
        }
    }
}

// Functions to be able to encode and decode protocol permission modes between JSON and Swift enum types
extension OIPPermissionMode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self.init(protocolValue: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
