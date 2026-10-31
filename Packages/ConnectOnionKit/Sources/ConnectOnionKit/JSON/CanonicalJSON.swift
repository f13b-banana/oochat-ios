import Foundation

public enum CanonicalJSON {
    public static func string(from value: JSONValue) -> String {
        switch value {
        case .string(let text):
            return quote(text)
        case .number(let number):
            if number.rounded() == number, let integer = Int64(exactly: number) {
                return String(integer)
            }
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .object(let object):
            return "{" + object.keys.sorted().map { key in
                "\(quote(key)):\(string(from: object[key] ?? .null))"
            }.joined(separator: ",") + "}"
        case .array(let array):
            return "[" + array.map { string(from: $0) }.joined(separator: ",") + "]"
        case .null:
            return "null"
        }
    }

    public static func data(from object: [String: JSONValue]) -> Data {
        Data(string(from: .object(object)).utf8)
    }

    private static let shortEscapes: [UInt32: String] = [
        0x22: "\\\"",
        0x5c: "\\\\",
        0x08: "\\b",
        0x0c: "\\f",
        0x0a: "\\n",
        0x0d: "\\r",
        0x09: "\\t"
    ]

    private static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            result += escaped(scalar)
        }
        result += "\""
        return result
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        if let short = shortEscapes[scalar.value] {
            return short
        }
        switch scalar.value {
        case 0x20...0x7f:
            return String(scalar)
        case 0x00...0x1f, 0x80...0xffff:
            return String(format: "\\u%04x", scalar.value)
        default:
            let value = scalar.value - 0x10000
            let highSurrogate = 0xd800 + (value >> 10)
            let lowSurrogate = 0xdc00 + (value & 0x3ff)
            return String(format: "\\u%04x\\u%04x", highSurrogate, lowSurrogate)
        }
    }
}
