import Combine
import ConnectOnionKit

/// Settings consumes a small read/action surface instead of the entire chat feature model.
@MainActor
protocol SettingsFeatureModel: ObservableObject {
    var identity: StoredIdentity? { get }
    var connectionState: ConversationConnectionState { get }
    var activeConversation: Conversation? { get }

    func reconnect() async
    /// Where a Device Link reads and replaces this device's key.
    var deviceLinkKeyStore: any DeviceLinkKeyStore { get }
    /// After a Device Link replaced `previousAddress`: lock the chats made under it, show the new
    /// Address and reconnect as it.
    func adoptReplacedIdentity(previousAddress: String) async
    /// Giving Device: the Agent Name list a link sends.
    var linkAgentNames: [DeviceLinkAgentName] { get }
    /// Receiving Device: applies the giver's list after the key is replaced, before `adoptReplacedIdentity`.
    func applyLinkedAgentNames(_ list: [DeviceLinkAgentName]) throws
}

extension ChatViewModel: SettingsFeatureModel {
    var deviceLinkKeyStore: any DeviceLinkKeyStore { identityStore }
}
