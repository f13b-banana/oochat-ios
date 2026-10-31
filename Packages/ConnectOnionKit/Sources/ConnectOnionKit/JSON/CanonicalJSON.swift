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

    private static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5c:
                result += "\\\\"
            case 0x08:
                result += "\\b"
            case 0x0c:
                result += "\\f"
            case 0x0a:
                result += "\\n"
            case 0x0d:
                result += "\\r"
            case 0x09:
                result += "\\t"
            case 0x00...0x1f:
                result += String(format: "\\u%04x", scalar.value)
            case 0x20...0x7f:
                result.append(String(scalar))
            case 0x80...0xffff:
                result += String(format: "\\u%04x", scalar.value)
            default:
                let value = scalar.value - 0x10000
                let highSurrogate = 0xd800 + (value >> 10)
                let lowSurrogate = 0xdc00 + (value & 0x3ff)
                result += String(
                    format: "\\u%04x\\u%04x",
                    highSurrogate,
                    lowSurrogate
                )
            }
        }
        result += "\""
        return result
    }
}
