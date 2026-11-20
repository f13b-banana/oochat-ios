import Foundation

/// A chat's title, from its first real message. Both apps title chats this way, once.
public enum ChatTitle {
    /// Long enough that the row, not the title, does the truncating.
    public static let maximumLength = 100

    /// nil while the message can't name the chat: empty, or a slash command such as `/hello`.
    public static func from(_ message: String) -> String? {
        guard let line = message
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }),
              !line.hasPrefix("/") else {
            return nil
        }
        let words = line.split(whereSeparator: \.isWhitespace)
        var title = ""
        for word in words {
            let next = title.isEmpty ? String(word) : "\(title) \(word)"
            guard next.count <= maximumLength else {
                break
            }
            title = next
        }
        // A single word longer than the cap is cut, still without dots.
        return title.isEmpty ? String(line.prefix(maximumLength)) : title
    }
}
