import Foundation
import SwiftData
import ConnectOnionKit

@MainActor
final class SwiftDataConversationRepository: ConversationRepository {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let activeAgentKey = "connectonion.native-ios.swiftdata.activeAgent"
    private let activeConversationKey = "connectonion.native-ios.swiftdata.activeConversation"

    init(inMemory: Bool = false, storeURL: URL? = nil, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(url: storeURL)
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        }
        let schema = Schema(versionedSchema: StoredModelsSchemaV4.self)
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: StoredModelsMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            // Stores written before schema versioning hash-match no plan version, which makes
            // the staged open throw. A plan-less open lightweight-infers them directly to the
            // current shape; once saved, later launches match the schema through the plan.
            container = try ModelContainer(for: schema, configurations: configuration)
        }
        context = ModelContext(container)
        try repairLegacyMessageIDs()
        try removeLegacyInitialMessages()
        try removeStaleThinkingMessages()
    }

    /// Stores written before `StoredMessage.messageID` existed carry the raw server ID in
    /// `id` and the lightweight-migration default ("") in `messageID`. Rewrite such rows
    /// once into the composite-key form; the empty-`messageID` predicate makes this a
    /// no-op on healthy stores. Runs before any load or write so callers never observe
    /// half-migrated rows.
    private func repairLegacyMessageIDs() throws {
        let legacy = try context.fetch(FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.messageID == "" }
        ))
        guard !legacy.isEmpty else { return }
        for message in legacy {
            // A message with no conversation is already unreachable, and giving it an
            // empty-scope composite key risks colliding with another orphan. Drop it.
            guard let conversationID = message.conversation?.id else {
                context.delete(message)
                continue
            }
            message.messageID = message.id
            message.id = StoredMessage.compositeID(
                conversationID: conversationID,
                messageID: message.messageID
            )
        }
        try save()
    }

    /// Older app versions inserted a synthetic assistant message into every new chat.
    /// Remove only that exact legacy bubble so existing conversations open cleanly while
    /// preserving user-authored messages that happen to mention ConnectOnion.
    private func removeLegacyInitialMessages() throws {
        let messages = try context.fetch(FetchDescriptor<StoredMessage>(
            predicate: #Predicate {
                $0.roleRaw == "agent"
                    && $0.content == "ConnectOnion native iOS session is ready."
            }
        ))
        guard !messages.isEmpty else { return }
        messages.forEach(context.delete)
        try save()
    }

    /// `.thinking` bubbles are placeholders removed when a round-trip completes, fails, or is
    /// cancelled — none of which run if the process dies mid-send, leaving the placeholder on
    /// disk forever. No in-flight round-trip survives a launch, so every persisted one is stale.
    private func removeStaleThinkingMessages() throws {
        let thinkingRole = ChatRole.thinking.rawValue
        let messages = try context.fetch(FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.roleRaw == thinkingRole }
        ))
        guard !messages.isEmpty else { return }
        messages.forEach(context.delete)
        try save()
    }

    func load() -> ChatSnapshot {
        (try? loadResult().get()) ?? .empty
    }

    func loadResult() -> Result<ChatSnapshot, ConversationRepositoryError> {
        capture(.load) {
            let agents = try context.fetch(FetchDescriptor<StoredAgent>())
            let conversations = try context.fetch(FetchDescriptor<StoredConversation>())
            return ChatSnapshot(
                agents: agents.map(toAgent).sorted { $0.updatedAt > $1.updatedAt },
                conversations: conversations.map(toConversation).sorted { $0.updatedAt > $1.updatedAt },
                activeAgentID: defaults.string(forKey: activeAgentKey),
                activeConversationID: defaults.string(forKey: activeConversationKey)
            )
        }
    }

    func upsertConversation(_ conversation: Conversation) {
        _ = upsertConversationResult(conversation)
    }

    func upsertConversationResult(_ conversation: Conversation) -> Result<Void, ConversationRepositoryError> {
        capture(.saveConversation) {
            if let stored = try storedConversation(id: conversation.id) {
                apply(conversation, to: stored)
            } else {
                insertConversation(conversation)
            }
            try save()
        }
    }

    func upsertMessageResult(
        _ message: ChatMessage,
        in conversation: Conversation
    ) -> Result<Void, ConversationRepositoryError> {
        capture(.saveConversation) {
            guard let stored = try storedConversation(id: conversation.id) else {
                insertConversation(conversation)
                try save()
                return
            }
            applyMetadata(conversation, to: stored)
            if let storedMessage = stored.messages.first(where: { $0.messageID == message.id }) {
                apply(message, to: storedMessage)
            } else {
                let newMessage = insert(toStoredMessage(message, conversationID: conversation.id))
                newMessage.conversation = stored
                stored.messages.append(newMessage)
            }
            try save()
        }
    }

    func updateConversationMetadataResult(
        _ conversation: Conversation
    ) -> Result<Void, ConversationRepositoryError> {
        capture(.saveConversation) {
            guard let stored = try storedConversation(id: conversation.id) else {
                insertConversation(conversation)
                try save()
                return
            }
            applyMetadata(conversation, to: stored)
            try save()
        }
    }

    func deleteConversation(id: String) {
        _ = deleteConversationResult(id: id)
    }

    func deleteConversationResult(id: String) -> Result<Void, ConversationRepositoryError> {
        capture(.deleteConversation) {
            guard let stored = try storedConversation(id: id) else { return }
            context.delete(stored)
            try save()
        }
    }

    func upsertAgent(_ agent: SavedAgent) {
        _ = upsertAgentResult(agent)
    }

    func upsertAgentResult(_ agent: SavedAgent) -> Result<Void, ConversationRepositoryError> {
        capture(.saveAgent) {
            if let stored = try storedAgent(id: agent.id) {
                apply(agent, to: stored)
            } else {
                context.insert(toStoredAgent(agent))
            }
            try save()
        }
    }

    func deleteAgent(id: String) {
        _ = deleteAgentResult(id: id)
    }

    func deleteAgentResult(id: String) -> Result<Void, ConversationRepositoryError> {
        // Cascade by agentID only. Multiple agents can share one address, so an address-based
        // cascade would wrongly delete a sibling agent's conversations.
        capture(.deleteAgent) {
            if let stored = try storedAgent(id: id) {
                context.delete(stored)
            }
            let owned = try context.fetch(FetchDescriptor<StoredConversation>(
                predicate: #Predicate { $0.agentID == id }
            ))
            owned.forEach(context.delete)
            try save()
        }
    }

    func saveActive(agentID: String?, conversationID: String?) {
        setActive(agentID, forKey: activeAgentKey)
        setActive(conversationID, forKey: activeConversationKey)
    }

    /// Case- and diacritic-insensitive search over conversation titles and message content,
    /// run as two indexed `#Predicate` fetches and unioned by conversation.
    func search(_ query: String) -> [Conversation] {
        (try? searchResult(query).get()) ?? []
    }

    func searchResult(_ query: String) -> Result<[Conversation], ConversationRepositoryError> {
        capture(.search) {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else {
                return try loadResult().get().conversations
            }
            var matched: [String: StoredConversation] = [:]
            let titleHits = try context.fetch(FetchDescriptor<StoredConversation>(
                predicate: #Predicate { $0.title.localizedStandardContains(needle) }
            ))
            for conversation in titleHits {
                matched[conversation.id] = conversation
            }
            let messageHits = try context.fetch(FetchDescriptor<StoredMessage>(
                predicate: #Predicate { $0.content.localizedStandardContains(needle) }
            ))
            for message in messageHits {
                if let conversation = message.conversation {
                    matched[conversation.id] = conversation
                }
            }
            return matched.values.map(toConversation).sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func storedAgent(id: String) throws -> StoredAgent? {
        try context.fetch(FetchDescriptor<StoredAgent>(predicate: #Predicate { $0.id == id })).first
    }

    private func storedConversation(id: String) throws -> StoredConversation? {
        try context.fetch(FetchDescriptor<StoredConversation>(predicate: #Predicate { $0.id == id })).first
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func capture<Value>(
        _ operation: ConversationRepositoryError.Operation,
        work: () throws -> Value
    ) -> Result<Value, ConversationRepositoryError> {
        do {
            return .success(try work())
        } catch let error as ConversationRepositoryError {
            return .failure(error)
        } catch {
            context.rollback()
            return .failure(ConversationRepositoryError(operation: operation, underlyingError: error))
        }
    }

    private func setActive(_ id: String?, forKey key: String) {
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func apply(_ agent: SavedAgent, to stored: StoredAgent) {
        stored.name = agent.name
        stored.address = agent.address
        stored.createdAt = agent.createdAt
        stored.updatedAt = agent.updatedAt
    }

    private func apply(_ conversation: Conversation, to stored: StoredConversation) {
        applyMetadata(conversation, to: stored)
        syncMessages(conversation.messages, of: stored)
    }

    private func applyMetadata(_ conversation: Conversation, to stored: StoredConversation) {
        stored.title = conversation.title
        stored.agentID = conversation.agentID
        stored.agentAddress = conversation.agentAddress
        stored.modeRaw = conversation.mode.rawValue
        stored.createdAt = conversation.createdAt
        stored.updatedAt = conversation.updatedAt
        stored.serverSessionData = encodeSession(conversation.serverSession)
    }

    private func syncMessages(_ messages: [ChatMessage], of stored: StoredConversation) {
        // StoredMessage.id is a composite; match on the original messageID.
        let keep = Set(messages.map(\.id))
        for message in stored.messages where !keep.contains(message.messageID) {
            context.delete(message)
        }
        var existing: [String: StoredMessage] = [:]
        for message in stored.messages {
            existing[message.messageID] = message
        }
        for message in messages {
            if let storedMessage = existing[message.id] {
                // Existing rows keep their position while streamed tool results update in place.
                apply(message, to: storedMessage)
            } else {
                let newMessage = insert(toStoredMessage(message, conversationID: stored.id))
                newMessage.conversation = stored
                stored.messages.append(newMessage)
            }
        }
    }

    /// Register a message with the context explicitly rather than relying on it
    /// being reachable through a persisted parent's to-many relationship.
    ///
    /// This is the documented shape and is kept for that reason. It is NOT the
    /// cause of the iOS 17 persistence failures: those 22 tests fail identically
    /// with and without it.
    @discardableResult
    private func insert(_ message: StoredMessage) -> StoredMessage {
        context.insert(message)
        return message
    }

    /// Insert a conversation and every message it arrived with.
    ///
    /// `toStoredConversation` builds the messages inside the initialiser, so this
    /// registers them alongside the parent. Same caveat as `insert(_:)` — correct
    /// practice, but not what makes iOS 17 fail.
    private func insertConversation(_ conversation: Conversation) {
        let stored = toStoredConversation(conversation)
        context.insert(stored)
        for message in stored.messages {
            context.insert(message)
            // Set the inverse explicitly. Assigning a parent's to-many array is
            // enough on iOS 18 and later — SwiftData fills the back-reference in.
            // On iOS 17 it does not, and a relationship written from one side only
            // reads back empty from both: `upsert` returns success, the
            // conversation is stored, and `conversation.messages` is [].
            //
            // That is what made 22 persistence tests fail on iOS 17.5 while
            // passing on iOS 26 — the write never errored, so nothing surfaced.
            message.conversation = stored
        }
    }

    private func apply(_ message: ChatMessage, to stored: StoredMessage) {
        stored.roleRaw = message.role.rawValue
        stored.deliveryStateRaw = message.deliveryState.rawValue
        stored.content = message.content
        stored.imageAttachmentsData = encodeImageAttachments(message.images)
        stored.fileAttachmentsData = encodeFileAttachments(message.files)
        stored.toolName = message.toolName
        stored.toolArgumentsData = encodeToolArguments(message.toolArguments)
        stored.toolStateRaw = message.toolState?.rawValue
    }

    private func toAgent(_ stored: StoredAgent) -> SavedAgent {
        SavedAgent(
            id: stored.id,
            address: stored.address,
            name: stored.name,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        )
    }

    private func toConversation(_ stored: StoredConversation) -> Conversation {
        Conversation(
            id: stored.id,
            title: stored.title,
            agentID: stored.agentID,
            agentAddress: stored.agentAddress,
            mode: ChatMode(rawValue: stored.modeRaw) ?? .safe,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            messages: stored.messages
                .sorted { $0.createdAt < $1.createdAt }
                .map(toMessage),
            serverSession: decodeSession(stored.serverSessionData)
        )
    }

    private func toMessage(_ stored: StoredMessage) -> ChatMessage {
        ChatMessage(
            id: stored.messageID,
            role: ChatRole(rawValue: stored.roleRaw) ?? .agent,
            content: stored.content,
            createdAt: stored.createdAt,
            deliveryState: MessageDeliveryState(rawValue: stored.deliveryStateRaw) ?? .sent,
            images: decodeImageAttachments(stored.imageAttachmentsData),
            files: decodeFileAttachments(stored.fileAttachmentsData),
            toolName: stored.toolName,
            toolArguments: decodeToolArguments(stored.toolArgumentsData),
            toolState: stored.toolStateRaw.flatMap(ToolCallState.init(rawValue:))
        )
    }

    private func toStoredAgent(_ agent: SavedAgent) -> StoredAgent {
        StoredAgent(
            id: agent.id,
            name: agent.name,
            address: agent.address,
            createdAt: agent.createdAt,
            updatedAt: agent.updatedAt
        )
    }

    private func toStoredConversation(_ conversation: Conversation) -> StoredConversation {
        StoredConversation(
            id: conversation.id,
            title: conversation.title,
            agentID: conversation.agentID,
            agentAddress: conversation.agentAddress,
            modeRaw: conversation.mode.rawValue,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            serverSessionData: encodeSession(conversation.serverSession),
            messages: conversation.messages.map { toStoredMessage($0, conversationID: conversation.id) }
        )
    }

    private func toStoredMessage(_ message: ChatMessage, conversationID: String) -> StoredMessage {
        StoredMessage(
            messageID: message.id,
            conversationID: conversationID,
            roleRaw: message.role.rawValue,
            content: message.content,
            createdAt: message.createdAt,
            deliveryStateRaw: message.deliveryState.rawValue,
            imageAttachmentsData: encodeImageAttachments(message.images),
            fileAttachmentsData: encodeFileAttachments(message.files),
            toolName: message.toolName,
            toolArgumentsData: encodeToolArguments(message.toolArguments),
            toolStateRaw: message.toolState?.rawValue
        )
    }

    private func encodeSession(_ session: [String: JSONValue]?) -> Data? {
        guard let session else { return nil }
        return try? JSONEncoder().encode(session)
    }

    private func decodeSession(_ data: Data?) -> [String: JSONValue]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func encodeToolArguments(_ arguments: [String: JSONValue]?) -> Data? {
        guard let arguments else { return nil }
        return try? JSONEncoder().encode(arguments)
    }

    private func decodeToolArguments(_ data: Data?) -> [String: JSONValue]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func encodeImageAttachments(_ images: [ChatImageAttachment]) -> Data? {
        guard !images.isEmpty else { return nil }
        return try? JSONEncoder().encode(images)
    }

    private func decodeImageAttachments(_ data: Data?) -> [ChatImageAttachment] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([ChatImageAttachment].self, from: data)) ?? []
    }

    private func encodeFileAttachments(_ files: [ChatFileAttachment]) -> Data? {
        guard !files.isEmpty else { return nil }
        return try? JSONEncoder().encode(files)
    }

    private func decodeFileAttachments(_ data: Data?) -> [ChatFileAttachment] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([ChatFileAttachment].self, from: data)) ?? []
    }
}
