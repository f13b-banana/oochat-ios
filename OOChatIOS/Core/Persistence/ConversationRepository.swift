import Foundation

struct ConversationRepositoryError: LocalizedError {
    enum Operation: String {
        case load = "load your conversations"
        case saveConversation = "save the conversation"
        case deleteConversation = "delete the conversation"
        case saveAgent = "save the agent"
        case deleteAgent = "delete the agent"
        case search = "search conversations"

        // error msg
        var consequence: String {
            switch self {
            case .load:
                return "Your past conversations may not appear."
            case .saveConversation:
                return "Your latest messages may be missing when you reopen the app."
            case .deleteConversation:
                return "It may reappear when you reopen the app."
            case .saveAgent:
                return "This agent may be missing when you reopen the app."
            case .deleteAgent:
                return "It may reappear when you reopen the app."
            case .search:
                return "Some results may be missing."
            }
        }
    }

    let operation: Operation
    let underlyingError: Error

    var errorDescription: String? {
        "Couldn’t \(operation.rawValue). \(operation.consequence) (Details: \(underlyingError.localizedDescription))"
    }
}

/// Persistence boundary for chat state. Reads hydrate the in-memory model once at launch
/// (`load`); every mutation is a granular, single-row write. `search` runs as an indexed
/// query against the store rather than filtering the in-memory list.
///
/// `@MainActor`-isolated: the sole caller is the main-actor `ChatViewModel`, and the
/// implementation keeps a single non-thread-safe `ModelContext`, so isolation is enforced
/// at compile time rather than left as a "happens to be safe" assumption.
@MainActor
protocol ConversationRepository {
    func load() -> ChatSnapshot

    func upsertConversation(_ conversation: Conversation)
    func deleteConversation(id: String)
    func upsertAgent(_ agent: SavedAgent)
    func deleteAgent(id: String)
    func saveActive(agentID: String?, conversationID: String?)
    func search(_ query: String) -> [Conversation]

    /// Unsent composer text per conversation ID, so a draft survives a relaunch.
    func loadDrafts() -> [String: String]
    func saveDrafts(_ drafts: [String: String])

    /// Result-returning variants let feature code surface persistence failures while the
    /// compatibility methods above keep existing callers source-compatible during migration.
    func loadResult() -> Result<ChatSnapshot, ConversationRepositoryError>
    func upsertConversationResult(_ conversation: Conversation) -> Result<Void, ConversationRepositoryError>
    func upsertMessageResult(
        _ message: ChatMessage,
        in conversation: Conversation
    ) -> Result<Void, ConversationRepositoryError>
    func updateConversationMetadataResult(
        _ conversation: Conversation
    ) -> Result<Void, ConversationRepositoryError>
    func deleteConversationResult(id: String) -> Result<Void, ConversationRepositoryError>
    func upsertAgentResult(_ agent: SavedAgent) -> Result<Void, ConversationRepositoryError>
    func deleteAgentResult(id: String) -> Result<Void, ConversationRepositoryError>
    func searchResult(_ query: String) -> Result<[Conversation], ConversationRepositoryError>
}

extension ConversationRepository {
    func loadDrafts() -> [String: String] { [:] }
    func saveDrafts(_ drafts: [String: String]) {}

    func loadResult() -> Result<ChatSnapshot, ConversationRepositoryError> {
        .success(load())
    }

    func upsertConversationResult(_ conversation: Conversation) -> Result<Void, ConversationRepositoryError> {
        upsertConversation(conversation)
        return .success(())
    }

    func upsertMessageResult(
        _ message: ChatMessage,
        in conversation: Conversation
    ) -> Result<Void, ConversationRepositoryError> {
        upsertConversationResult(conversation)
    }

    func updateConversationMetadataResult(
        _ conversation: Conversation
    ) -> Result<Void, ConversationRepositoryError> {
        upsertConversationResult(conversation)
    }

    func deleteConversationResult(id: String) -> Result<Void, ConversationRepositoryError> {
        deleteConversation(id: id)
        return .success(())
    }

    func upsertAgentResult(_ agent: SavedAgent) -> Result<Void, ConversationRepositoryError> {
        upsertAgent(agent)
        return .success(())
    }

    func deleteAgentResult(id: String) -> Result<Void, ConversationRepositoryError> {
        deleteAgent(id: id)
        return .success(())
    }

    func searchResult(_ query: String) -> Result<[Conversation], ConversationRepositoryError> {
        .success(search(query))
    }
}
