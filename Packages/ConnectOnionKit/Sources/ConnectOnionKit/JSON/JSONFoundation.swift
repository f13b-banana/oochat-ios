import Foundation

extension JSONValue {

    // from connectonionprotocoltypes.swift
    public init(any value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        /// Json Serialisation gives NSNumber 1, 0 and true alike, as Bool acccepts all three
        /// Only a real CFBoolean is a JSON bool, everything else is j a number
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ?
                .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [String: Any]:
            self = .object(value.mapValues(Self.init(any:)))
        case let value as [Any]:
            self = .array(value.map(Self.init(any:)))
        default:
            self = .null
        }
    }

    // reversed
    public var anyValue: Any {
        switch self {
        case .string(let value):
            return value
        case .bool(let value):
            return value
        case .number(let value):
            if let integer = Int64(exactly: value) {
                return NSNumber(value: integer)
            }
            return NSNumber(value: value)
        case .object(let value):
            return value.mapValues { $0.anyValue }
        case .array(let value):
            return value.map { $0.anyValue }
        case .null:
            return NSNull()
        }
    }
}
