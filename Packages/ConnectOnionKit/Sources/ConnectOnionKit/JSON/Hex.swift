import Foundation

public enum Hex {
    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ text: String) -> Data? {
        let clean = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        guard clean.count.isMultiple(of: 2) else {
            return nil
        }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }
}
