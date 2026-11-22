import Foundation

/// The agent pane searches the picked agent's chats only.
enum ChatSidebarSearch {
    static func query(from text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
