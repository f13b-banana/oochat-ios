//
//  JSONValue+Accessors.swift
//  ConnectOnionKit
//
//

// Accessors used by the OIP server frame decoder

extension JSONValue {
    public var intValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value == value.rounded(),
              abs(value) < 9_007_199_254_740_992 else {
            return nil
        }
        return Int(value)
    }
    public var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }
}
