// Keep released schema versions immutable so existing stores continue to match them.

import Foundation
import SwiftData

typealias StoredAgent = StoredModelsSchemaV4.StoredAgent
typealias StoredConversation = StoredModelsSchemaV4.StoredConversation
typealias StoredMessage = StoredModelsSchemaV4.StoredMessage

// V1 pins the shape shipped when schema versioning was adopted (2026-07). Structural changes
// go into a new StoredModelsSchemaV(N+1) enum plus a MigrationStage in StoredModelsMigrationPlan;
// never edit a shipped version's models in place, or existing stores stop hash-matching it.
enum StoredModelsSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredAgent.self, StoredConversation.self, StoredMessage.self]
    }

    @Model
    final class StoredAgent {
        @Attribute(.unique) var id: String
        var name: String
        var address: String
        var token: String = ""
        var createdAt: Date
        var updatedAt: Date

        init(id: String, name: String, address: String, token: String, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.name = name
            self.address = address
            self.token = token
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredConversation {
        @Attribute(.unique) var id: String
        var title: String
        var agentID: String?
        var agentAddress: String
        var modeRaw: String
        var createdAt: Date
        var updatedAt: Date
        var serverSessionData: Data?
        @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
        var messages: [StoredMessage]

        init(
            id: String,
            title: String,
            agentID: String?,
            agentAddress: String,
            modeRaw: String,
            createdAt: Date,
            updatedAt: Date,
            serverSessionData: Data?,
            messages: [StoredMessage]
        ) {
            self.id = id
            self.title = title
            self.agentID = agentID
            self.agentAddress = agentAddress
            self.modeRaw = modeRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serverSessionData = serverSessionData
            self.messages = messages
        }
    }

    @Model
    final class StoredMessage {
        // Server-chosen message IDs are not globally unique, so `id` is a conversation-scoped
        // composite; `messageID` keeps the original ID for in-conversation matching. The ""
        // default lets stores written before this field existed open via lightweight migration;
        // SwiftDataConversationRepository backfills the real values on init.
        @Attribute(.unique) var id: String
        var messageID: String = ""
        var roleRaw: String
        var content: String
        var createdAt: Date
        var deliveryStateRaw: String = "sent"
        var toolName: String?
        var toolArgumentsData: Data?
        var toolStateRaw: String?
        var conversation: StoredConversation?

        init(
            messageID: String,
            conversationID: String,
            roleRaw: String,
            content: String,
            createdAt: Date,
            deliveryStateRaw: String = "sent",
            toolName: String? = nil,
            toolArgumentsData: Data? = nil,
            toolStateRaw: String? = nil
        ) {
            self.id = StoredMessage.compositeID(conversationID: conversationID, messageID: messageID)
            self.messageID = messageID
            self.roleRaw = roleRaw
            self.content = content
            self.createdAt = createdAt
            self.deliveryStateRaw = deliveryStateRaw
            self.toolName = toolName
            self.toolArgumentsData = toolArgumentsData
            self.toolStateRaw = toolStateRaw
        }

        // Length-prefixing the conversation component keeps the key unambiguous for arbitrary
        // IDs (including ones containing "#"), so distinct (conversation, message) pairs can
        // never produce the same key.
        static func compositeID(conversationID: String, messageID: String) -> String {
            "\(conversationID.utf8.count)#\(conversationID)#\(messageID)"
        }
    }
}

// V2 adds persisted image attachments to messages. The attachment blob uses external storage
// because a single photo can be several megabytes and should not inflate the SQLite row itself.
enum StoredModelsSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredAgent.self, StoredConversation.self, StoredMessage.self]
    }

    @Model
    final class StoredAgent {
        @Attribute(.unique) var id: String
        var name: String
        var address: String
        var token: String = ""
        var createdAt: Date
        var updatedAt: Date

        init(id: String, name: String, address: String, token: String, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.name = name
            self.address = address
            self.token = token
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredConversation {
        @Attribute(.unique) var id: String
        var title: String
        var agentID: String?
        var agentAddress: String
        var modeRaw: String
        var createdAt: Date
        var updatedAt: Date
        var serverSessionData: Data?
        @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
        var messages: [StoredMessage]

        init(
            id: String,
            title: String,
            agentID: String?,
            agentAddress: String,
            modeRaw: String,
            createdAt: Date,
            updatedAt: Date,
            serverSessionData: Data?,
            messages: [StoredMessage]
        ) {
            self.id = id
            self.title = title
            self.agentID = agentID
            self.agentAddress = agentAddress
            self.modeRaw = modeRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serverSessionData = serverSessionData
            self.messages = messages
        }
    }

    @Model
    final class StoredMessage {
        @Attribute(.unique) var id: String
        var messageID: String = ""
        var roleRaw: String
        var content: String
        var createdAt: Date
        var deliveryStateRaw: String = "sent"
        @Attribute(.externalStorage) var imageAttachmentsData: Data?
        var toolName: String?
        var toolArgumentsData: Data?
        var toolStateRaw: String?
        var conversation: StoredConversation?

        init(
            messageID: String,
            conversationID: String,
            roleRaw: String,
            content: String,
            createdAt: Date,
            deliveryStateRaw: String = "sent",
            imageAttachmentsData: Data? = nil,
            toolName: String? = nil,
            toolArgumentsData: Data? = nil,
            toolStateRaw: String? = nil
        ) {
            self.id = StoredMessage.compositeID(conversationID: conversationID, messageID: messageID)
            self.messageID = messageID
            self.roleRaw = roleRaw
            self.content = content
            self.createdAt = createdAt
            self.deliveryStateRaw = deliveryStateRaw
            self.imageAttachmentsData = imageAttachmentsData
            self.toolName = toolName
            self.toolArgumentsData = toolArgumentsData
            self.toolStateRaw = toolStateRaw
        }

        static func compositeID(conversationID: String, messageID: String) -> String {
            "\(conversationID.utf8.count)#\(conversationID)#\(messageID)"
        }
    }
}

// V3 adds persisted file attachments. Files are kept in a separate external-storage blob so
// existing image-only rows migrate without rewriting their attachment data.
enum StoredModelsSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredAgent.self, StoredConversation.self, StoredMessage.self]
    }

    @Model
    final class StoredAgent {
        @Attribute(.unique) var id: String
        var name: String
        var address: String
        var token: String = ""
        var createdAt: Date
        var updatedAt: Date

        init(id: String, name: String, address: String, token: String, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.name = name
            self.address = address
            self.token = token
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredConversation {
        @Attribute(.unique) var id: String
        var title: String
        var agentID: String?
        var agentAddress: String
        var modeRaw: String
        var createdAt: Date
        var updatedAt: Date
        var serverSessionData: Data?
        @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
        var messages: [StoredMessage]

        init(
            id: String,
            title: String,
            agentID: String?,
            agentAddress: String,
            modeRaw: String,
            createdAt: Date,
            updatedAt: Date,
            serverSessionData: Data?,
            messages: [StoredMessage]
        ) {
            self.id = id
            self.title = title
            self.agentID = agentID
            self.agentAddress = agentAddress
            self.modeRaw = modeRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serverSessionData = serverSessionData
            self.messages = messages
        }
    }

    @Model
    final class StoredMessage {
        @Attribute(.unique) var id: String
        var messageID: String = ""
        var roleRaw: String
        var content: String
        var createdAt: Date
        var deliveryStateRaw: String = "sent"
        @Attribute(.externalStorage) var imageAttachmentsData: Data?
        @Attribute(.externalStorage) var fileAttachmentsData: Data?
        var toolName: String?
        var toolArgumentsData: Data?
        var toolStateRaw: String?
        var conversation: StoredConversation?

        init(
            messageID: String,
            conversationID: String,
            roleRaw: String,
            content: String,
            createdAt: Date,
            deliveryStateRaw: String = "sent",
            imageAttachmentsData: Data? = nil,
            fileAttachmentsData: Data? = nil,
            toolName: String? = nil,
            toolArgumentsData: Data? = nil,
            toolStateRaw: String? = nil
        ) {
            self.id = StoredMessage.compositeID(conversationID: conversationID, messageID: messageID)
            self.messageID = messageID
            self.roleRaw = roleRaw
            self.content = content
            self.createdAt = createdAt
            self.deliveryStateRaw = deliveryStateRaw
            self.imageAttachmentsData = imageAttachmentsData
            self.fileAttachmentsData = fileAttachmentsData
            self.toolName = toolName
            self.toolArgumentsData = toolArgumentsData
            self.toolStateRaw = toolStateRaw
        }

        static func compositeID(conversationID: String, messageID: String) -> String {
            "\(conversationID.utf8.count)#\(conversationID)#\(messageID)"
        }
    }
}

// V4 drops StoredAgent.token. Agents are addressed by their Ed25519 address alone, so the field
// carried a credential that nothing read; deleting a property is a lightweight migration and the
// stored values go away with the column.
enum StoredModelsSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredAgent.self, StoredConversation.self, StoredMessage.self]
    }

    @Model
    final class StoredAgent {
        @Attribute(.unique) var id: String
        var name: String
        var address: String
        var createdAt: Date
        var updatedAt: Date

        init(id: String, name: String, address: String, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.name = name
            self.address = address
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredConversation {
        @Attribute(.unique) var id: String
        var title: String
        var agentID: String?
        var agentAddress: String
        var modeRaw: String
        var createdAt: Date
        var updatedAt: Date
        var serverSessionData: Data?
        @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
        var messages: [StoredMessage]

        init(
            id: String,
            title: String,
            agentID: String?,
            agentAddress: String,
            modeRaw: String,
            createdAt: Date,
            updatedAt: Date,
            serverSessionData: Data?,
            messages: [StoredMessage]
        ) {
            self.id = id
            self.title = title
            self.agentID = agentID
            self.agentAddress = agentAddress
            self.modeRaw = modeRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serverSessionData = serverSessionData
            self.messages = messages
        }
    }

    @Model
    final class StoredMessage {
        @Attribute(.unique) var id: String
        var messageID: String = ""
        var roleRaw: String
        var content: String
        var createdAt: Date
        var deliveryStateRaw: String = "sent"
        @Attribute(.externalStorage) var imageAttachmentsData: Data?
        @Attribute(.externalStorage) var fileAttachmentsData: Data?
        var toolName: String?
        var toolArgumentsData: Data?
        var toolStateRaw: String?
        var conversation: StoredConversation?

        init(
            messageID: String,
            conversationID: String,
            roleRaw: String,
            content: String,
            createdAt: Date,
            deliveryStateRaw: String = "sent",
            imageAttachmentsData: Data? = nil,
            fileAttachmentsData: Data? = nil,
            toolName: String? = nil,
            toolArgumentsData: Data? = nil,
            toolStateRaw: String? = nil
        ) {
            self.id = StoredMessage.compositeID(conversationID: conversationID, messageID: messageID)
            self.messageID = messageID
            self.roleRaw = roleRaw
            self.content = content
            self.createdAt = createdAt
            self.deliveryStateRaw = deliveryStateRaw
            self.imageAttachmentsData = imageAttachmentsData
            self.fileAttachmentsData = fileAttachmentsData
            self.toolName = toolName
            self.toolArgumentsData = toolArgumentsData
            self.toolStateRaw = toolStateRaw
        }

        static func compositeID(conversationID: String, messageID: String) -> String {
            "\(conversationID.utf8.count)#\(conversationID)#\(messageID)"
        }
    }
}

// Stores older than V1 (written before versioning) hash-match no version here and make the
// staged open throw; SwiftDataConversationRepository then falls back to a plan-less open whose
// lightweight inference carries them to the current shape, so later opens match the plan.
enum StoredModelsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            StoredModelsSchemaV1.self,
            StoredModelsSchemaV2.self,
            StoredModelsSchemaV3.self,
            StoredModelsSchemaV4.self
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: StoredModelsSchemaV1.self,
                toVersion: StoredModelsSchemaV2.self
            ),
            .lightweight(
                fromVersion: StoredModelsSchemaV2.self,
                toVersion: StoredModelsSchemaV3.self
            ),
            .lightweight(
                fromVersion: StoredModelsSchemaV3.self,
                toVersion: StoredModelsSchemaV4.self
            )
        ]
    }
}
