import Combine
import ConnectOnionKit
import Foundation
import UIKit

enum ConversationActivityState: Hashable {
    case actionRequired
    case working
    case completedUnread
    case failedDelivery
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var identity: StoredIdentity?
    // Request mode per conversation: Remains set until mode_changed confirms it.
    @Published private(set) var pendingModeByConversationID: [String: ChatMode] = [:]
    // Server reported full access turns budget, keyed by conversation.
    @Published private(set) var fullAccessTurnsLeftByConversationID: [String: Int] = [:]
    @Published var isConnecting = false
    @Published var errorMessage: String?
     /// Set when the agent answered -32010. The Incompatible screen shows while it is non-nil.
    @Published var incompatibility: OIPHandshake.Incompatibility?
    @Published var agentAddressDraft = ""
    @Published var prompt = "" {
        didSet {
            conversationState.updateActiveDraft(prompt)
        }
    }
    @Published var pendingImages: [ChatImageAttachment] = [] {
        didSet {
            guard let activeConversationID else {
                return
            }
            imageDraftsByConversationID[activeConversationID] = pendingImages
        }
    }
    @Published var pendingFiles: [ChatFileAttachment] = [] {
        didSet {
            guard let activeConversationID else {
                return
            }
            fileDraftsByConversationID[activeConversationID] = pendingFiles
        }
    }

    var isOffline: Bool {
        recoveryCoordinator.isOffline
    }

    var isOfflineBannerDismissed: Bool {
        recoveryCoordinator.isOfflineBannerDismissed
    }

    var shouldShowOfflineBanner: Bool {
        recoveryCoordinator.shouldShowOfflineBanner
    }

    var isRetryingConnectivity: Bool {
        recoveryCoordinator.isRetryingConnectivity
    }

    var recoveryTask: Task<Void, Never>? {
        recoveryCoordinator.recoveryTask
    }

    var probeTask: Task<Void, Never>? {
        recoveryCoordinator.probeTask
    }

    var disconnectTask: Task<Void, Never>? {
        recoveryCoordinator.disconnectTask
    }

    let interactionCoordinator: InteractionCoordinator
    let deliveryCoordinator: MessageDeliveryCoordinator
    let recoveryCoordinator: ConnectionRecoveryCoordinator
    let presenceCoordinator: AgentPresenceCoordinator
    let skillCoordinator: SkillLoadingCoordinator
    private var interactionChangeCancellable: AnyCancellable?
    private var deliveryChangeCancellable: AnyCancellable?
    private var recoveryChangeCancellable: AnyCancellable?
    private var presenceChangeCancellable: AnyCancellable?
    private var skillChangeCancellable: AnyCancellable?
    private var conversationStateChangeCancellable: AnyCancellable?
    private var persistenceErrorCancellable: AnyCancellable?
    private var offlineStateCancellable: AnyCancellable?
    /// Text of the banner currently raised by a connectivity failure, so going offline can
    /// retract it. Nothing else is retracted: a banner about a photo or the store is still
    /// news once the network drops.
    var connectivityErrorMessage: String?
    private var voiceInputChangeCancellable: AnyCancellable?
    var imageDraftsByConversationID: [String: [ChatImageAttachment]] = [:]
    var fileDraftsByConversationID: [String: [ChatFileAttachment]] = [:]
    let voiceInputController: VoiceInputController
    var backgroundDeliveryTaskID: UIBackgroundTaskIdentifier = .invalid

    var probeInterval: TimeInterval {
        get {
            recoveryCoordinator.probeInterval
        }
        set {
            recoveryCoordinator.probeInterval = newValue
        }
    }

    var presenceInterval: TimeInterval {
        get {
            presenceCoordinator.pollingInterval
        }
        set {
            presenceCoordinator.pollingInterval = newValue
        }
    }

    let conversationState: ConversationState
    var client: HostedAgentTransport

    var agents: [SavedAgent] {
        conversationState.agents
    }

    var conversations: [Conversation] {
        conversationState.conversations
    }

    var activeAgentID: String? {
        conversationState.activeAgentID
    }

    var activeConversationID: String? {
        conversationState.activeConversationID
    }

    var activeAgent: SavedAgent? {
        conversationState.activeAgent
    }

    var activeConversation: Conversation? {
        conversationState.activeConversation
    }

    var activeMode: ChatMode {
        activeConversation?.mode ?? .safe
    }

    var activePendingMode: ChatMode? {
        guard let id = activeConversationID else {
            return nil
        }
        return pendingModeByConversationID[id]
    }

    var activeFullAccessTurnsLeft: Int? {
        guard let id = activeConversationID else {
            return nil
        }
        return fullAccessTurnsLeftByConversationID[id]
    }

    // Full access only when the host listed it. Hidden until a CONNECTED arrives, as on macOS
    var offeredModes: [ChatMode] {
        let available = activeConversation
            .flatMap { deliveryCoordinator.availableModesByAgentAddress[$0.agentAddress] } ?? []
        return ChatMode.offered.filter { $0 != .ulw || available.contains(.fullAccess) }
    }

    var connectionState: ConversationConnectionState {
        guard let activeConversationID else {
            return .disconnected
        }
        return recoveryCoordinator.connectionState(forConversationID: activeConversationID)
    }

    /// Presence for the active agent, shared by the sidebar and toolbar.
    var isActiveAgentOnline: Bool {
        guard let activeAgent else {
            return false
        }
        return isAgentOnline(activeAgent)
    }

    var isProcessing: Bool {
        guard let activeConversationID else {
            return false
        }
        return deliveryCoordinator.isProcessing(conversationID: activeConversationID)
    }

    var voiceInputState: VoiceInputState {
        voiceInputController.state
    }

    var isVoiceInputActive: Bool {
        voiceInputController.isActive
    }

    var sendTask: Task<Void, Never>? {
        deliveryCoordinator.task(for: activeConversationID)
    }

    var activePendingApproval: PendingApproval? {
        interactionCoordinator.pendingApproval(for: activeConversationID)
    }

    var activePendingUlwCheckpoint: PendingUlwCheckpoint? {
        interactionCoordinator.pendingUlwCheckpoint(for: activeConversationID)
    }

    var activePendingPlanReview: PendingPlanReview? {
        interactionCoordinator.pendingPlanReview(for: activeConversationID)
    }

    var activePendingAskUser: PendingAskUser? {
        interactionCoordinator.pendingAskUser(for: activeConversationID)
    }

    var pendingInteractionID: String? {
        interactionCoordinator.pendingInteractionID(for: activeConversationID)
    }

    func isProcessing(conversationID: String) -> Bool {
        deliveryCoordinator.isProcessing(conversationID: conversationID)
    }

    func hasPendingInteraction(forConversationID conversationID: String) -> Bool {
        interactionCoordinator.hasPendingInteraction(for: conversationID)
    }

    func activityState(forConversationID conversationID: String) -> ConversationActivityState? {
        if interactionCoordinator.hasPendingInteraction(for: conversationID) {
            return .actionRequired
        }
        if deliveryCoordinator.isProcessing(conversationID: conversationID) {
            return .working
        }
        if conversationState.failedDeliveryConversationIDs.contains(conversationID) {
            return .failedDelivery
        }
        if conversationState.completedUnreadConversationIDs.contains(conversationID) {
            return .completedUnread
        }
        return nil
    }

    var backgroundActivityState: ConversationActivityState? {
        let backgroundConversationIDs = conversations.lazy
            .map(\.id)
            .filter { $0 != self.activeConversationID }
        let states = backgroundConversationIDs.compactMap(activityState(forConversationID:))

        if states.contains(.actionRequired) {
            return .actionRequired
        }
        if states.contains(.failedDelivery) {
            return .failedDelivery
        }
        if states.contains(.completedUnread) {
            return .completedUnread
        }
        return nil
    }

    var hasBackgroundPendingInteraction: Bool {
        interactionCoordinator.hasPendingInteraction(excluding: activeConversationID)
    }

    func hasFailedDelivery(forConversationID conversationID: String) -> Bool {
        conversationState.failedDeliveryConversationIDs.contains(conversationID)
    }

    /// A send that fails in a background conversation only raises the error banner when that
    /// conversation happens to be active, so surface it on the sidebar affordance too.
    var hasBackgroundDeliveryFailure: Bool {
        conversationState.failedDeliveryConversationIDs.contains { $0 != activeConversationID }
    }

    var needsBackgroundAttention: Bool {
        backgroundActivityState != nil
    }

    /// True when a running tool message duplicates the approval card already on screen, so the
    /// chat can hide the bubble and show only the card. The agent may name the tool differently
    /// in the two frames, hence the fallback to comparing rendered action summaries.
    func isToolCallCoveredByPendingApproval(_ message: ChatMessage, in conversationID: String) -> Bool {
        guard let approval = activePendingApproval,
              approval.conversationID == conversationID,
              message.role == .tool,
              message.toolState == .running,
              message.content.isEmpty else {
            return false
        }

        let messageArguments = message.toolArguments ?? [:]
        guard messageArguments == approval.request.arguments else {
            return false
        }

        if message.toolName == approval.request.tool {
            return true
        }

        return ToolActionSummary.requested(
            toolName: message.toolName ?? "tool",
            arguments: messageArguments
        ) == ToolActionSummary.requested(
            toolName: approval.request.tool,
            arguments: approval.request.arguments
        )
    }

    var onlineAgentCount: Int {
        agents.filter(isAgentOnline).count
    }

    func isAgentOnline(_ agent: SavedAgent) -> Bool {
        if presenceCoordinator.isOnline(address: agent.address) {
            return true
        }
        return conversations(for: agent).contains { conversation in
            recoveryCoordinator.connectionState(forConversationID: conversation.id) == .connected
        }
    }

    var slashSkillSuggestions: [AgentSkill] {
        skillCoordinator.suggestions(
            prompt: prompt,
            agentAddress: activeAgent?.address
        )
    }

    var shouldShowSlashSkillPicker: Bool {
        skillCoordinator.shouldShowSuggestions(
            prompt: prompt,
            agentAddress: activeAgent?.address
        )
    }

    init(
        store: ConversationRepository? = nil,
        identityStore: IdentityStore = IdentityStore(),
        client: HostedAgentTransport? = nil,
        networkMonitor: NetworkPathMonitoring? = nil,
        voiceInputController: VoiceInputController? = nil
    ) {
        let (store, storeError) = Self.resolveStore(store)
        let conversationState = ConversationState(store: store)
        let interactionCoordinator = InteractionCoordinator()
        let transport = client ?? HostedAgentClient(identityStore: identityStore)
        let deliveryCoordinator = MessageDeliveryCoordinator(
            conversationState: conversationState,
            interactionCoordinator: interactionCoordinator,
            transport: transport
        )
        let skillCoordinator = SkillLoadingCoordinator(transport: transport)
        let presenceCoordinator = AgentPresenceCoordinator(
            availabilityChecker: transport,
            agentAddresses: { conversationState.agents.map(\.address) }
        )
        let recoveryCoordinator = ConnectionRecoveryCoordinator(
            conversationState: conversationState,
            deliveryCoordinator: deliveryCoordinator,
            networkMonitor: networkMonitor ?? NetworkMonitor(),
            transport: transport
        )
        self.conversationState = conversationState
        self.interactionCoordinator = interactionCoordinator
        self.deliveryCoordinator = deliveryCoordinator
        self.recoveryCoordinator = recoveryCoordinator
        self.presenceCoordinator = presenceCoordinator
        self.skillCoordinator = skillCoordinator
        self.client = transport
        self.voiceInputController = voiceInputController ?? VoiceInputController()
        self.agentAddressDraft = conversationState.activeAgent?.address ?? ""
        do {
            self.identity = try identityStore.loadOrCreateIdentity()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        if let error = conversationState.persistenceError {
            self.errorMessage = error.localizedDescription
        }
        // A store failure is the most important startup error to show.
        if let storeError {
            self.errorMessage = "Couldn’t open your saved conversations, so this session won’t be saved. \(storeError.localizedDescription)"
        }
        observeCoordinators()
        recoveryCoordinator.start()
    }

    private static func resolveStore(
        _ store: ConversationRepository?
    ) -> (repository: ConversationRepository, error: Error?) {
        if let store {
            return (store, nil)
        }
        let outcome = ConversationRepositoryFactory.makeOutcome()
        return (outcome.repository, outcome.error)
    }

    /// Connects coordinator updates after all stored properties are ready.
    private func observeCoordinators() {
        recoveryCoordinator.onRecoveryError = { [weak self] conversationID, error in
            self?.presentConnectionError(error, forConversationID: conversationID)
        }
        recoveryCoordinator.onReconnect = { [weak self] agent in
            self?.skillCoordinator.refreshSkills(for: agent)
        }
        recoveryCoordinator.onNetworkAvailabilityChange = { [weak self] isOnline in
            self?.presenceCoordinator.networkAvailabilityDidChange(isOnline: isOnline)
        }
        deliveryCoordinator.onDeliveryError = { [weak self] conversationID, error in
            self?.presentConnectionError(error, forConversationID: conversationID)
        }
        deliveryCoordinator.onDeliveriesIdle = { [weak self] in
            self?.endBackgroundDeliveryHold()
        }
        // Covers our confirmations and the host's own (each full-access turn, and expiry).
        deliveryCoordinator.onModeChanged = { [weak self] conversationID, mode, turnsLeft in
            self?.fullAccessTurnsLeftByConversationID[conversationID] = mode == .fullAccess ? turnsLeft : nil
        }
        offlineStateCancellable = recoveryCoordinator.$isOffline
            .removeDuplicates()
            .sink { [weak self] isOffline in
                guard isOffline else {
                    return
                }
                self?.retractConnectivityError()
            }
        persistenceErrorCancellable = conversationState.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.errorMessage = error.localizedDescription
            }
        forwardChangesFromCoordinators()
    }

    /// The coordinators own the state the views read through this view model, so their
    /// changes have to reach SwiftUI as changes to this object.
    private func forwardChangesFromCoordinators() {
        interactionChangeCancellable = forwardingChanges(from: interactionCoordinator.objectWillChange)
        deliveryChangeCancellable = forwardingChanges(from: deliveryCoordinator.objectWillChange)
        recoveryChangeCancellable = forwardingChanges(from: recoveryCoordinator.objectWillChange)
        presenceChangeCancellable = forwardingChanges(from: presenceCoordinator.objectWillChange)
        skillChangeCancellable = forwardingChanges(from: skillCoordinator.objectWillChange)
        conversationStateChangeCancellable = forwardingChanges(from: conversationState.objectWillChange)
        voiceInputChangeCancellable = forwardingChanges(from: voiceInputController.objectWillChange)
    }

    private func forwardingChanges(from publisher: ObservableObjectPublisher) -> AnyCancellable {
        publisher.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func agent(withID id: String) -> SavedAgent? {
        conversationState.agent(withID: id)
    }

    func conversation(withID id: String) -> Conversation? {
        conversationState.conversation(withID: id)
    }

    func conversations(for agent: SavedAgent) -> [Conversation] {
        conversationState.conversations(for: agent)
    }

    func selectAgent(_ agent: SavedAgent) {
        conversationState.selectAgent(agent, currentDraft: prompt)
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        agentAddressDraft = agent.address
        skillCoordinator.loadSkillsIfNeeded(for: agent, isOffline: isOffline)
    }

    func selectConversation(_ conversation: Conversation) {
        conversationState.selectConversation(conversation, currentDraft: prompt)
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        if let agent = agent(for: conversation) {
            agentAddressDraft = agent.address
            skillCoordinator.loadSkillsIfNeeded(for: agent, isOffline: isOffline)
        }
    }

    func selectConversation(withID id: String) {
        guard let conversation = conversation(withID: id) else {
            return
        }
        selectConversation(conversation)
    }

    func createConversation(for agent: SavedAgent) -> Conversation {
        let conversation = conversationState.createConversation(for: agent, currentDraft: prompt)
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        recoveryCoordinator.setConnectionState(.disconnected, forConversationID: conversation.id)
        agentAddressDraft = agent.address
        return conversation
    }

    @discardableResult
    func saveAgent(id: String? = nil, name: String, address: String) -> SavedAgent? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard HostedAgentClient.isHostedAgentAddress(trimmedAddress) else {
            errorMessage = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            return nil
        }
        errorMessage = nil
        let existingAgent = id.flatMap { conversationState.agent(withID: $0) }
        let addressChanged = existingAgent.map { $0.address != trimmedAddress } ?? false
        let affectedConversationIDs = existingAgent.map {
            conversations(for: $0).map(\.id)
        } ?? []
        let next = conversationState.saveAgent(
            id: id,
            name: trimmedName,
            address: trimmedAddress
        )
        if addressChanged {
            for conversationID in affectedConversationIDs {
                recoveryCoordinator.setConnectionState(
                    .disconnected,
                    forConversationID: conversationID
                )
            }
        }
        agentAddressDraft = next.address
        presenceCoordinator.agentsDidChange()
        return next
    }

    func fetchAgentName(for address: String) async -> String? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(trimmedAddress) else {
            return nil
        }
        return try? await client.fetchAgentName(agentAddress: trimmedAddress)
    }

    func switchToAgentForChat(_ agent: SavedAgent) {
        agentAddressDraft = agent.address
        if let conversation = conversations(for: agent).first {
            conversationState.selectConversation(conversation, currentDraft: prompt)
            prompt = conversationState.activeDraft
        } else {
            _ = createConversation(for: agent)
        }
        restorePendingAttachmentDrafts()
        skillCoordinator.loadSkillsIfNeeded(for: agent, isOffline: isOffline)
    }

    func promptDidChange() {
        guard skillCoordinator.isSlashQuery(prompt), let activeAgent else {
            return
        }
        skillCoordinator.loadSkillsIfNeeded(for: activeAgent, isOffline: isOffline)
    }

    func prefetchActiveAgentSkills() {
        guard let activeAgent else {
            return
        }
        skillCoordinator.loadSkillsIfNeeded(for: activeAgent, isOffline: isOffline)
    }

    func selectSlashSkill(_ skill: AgentSkill) {
        prompt = "/\(skill.name) "
    }

    func deleteConversation(_ conversation: Conversation) {
        cancelPendingInteractions(forConversationID: conversation.id)
        recoveryCoordinator.removeConnectionState(forConversationID: conversation.id)
        conversationState.deleteConversation(conversation, currentDraft: prompt)
        imageDraftsByConversationID[conversation.id] = nil
        fileDraftsByConversationID[conversation.id] = nil
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
    }

    func deleteAgent(_ agent: SavedAgent) {
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        for conversationID in deletedConversationIDs {
            cancelPendingInteractions(forConversationID: conversationID)
            recoveryCoordinator.removeConnectionState(forConversationID: conversationID)
        }
        conversationState.deleteAgent(agent, currentDraft: prompt)
        presenceCoordinator.agentsDidChange()
        for conversationID in deletedConversationIDs {
            imageDraftsByConversationID[conversationID] = nil
            fileDraftsByConversationID[conversationID] = nil
        }
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        agentAddressDraft = activeAgent?.address ?? ""
    }

    /// Renames a conversation in place. Empty/whitespace titles and no-op renames are
    /// ignored. A rename is a metadata edit, not activity, so it deliberately does not
    /// reorder the list, bump `updatedAt`, or change the active conversation — only the
    /// title and its persisted row change.
    func renameConversation(_ conversation: Conversation, to title: String) {
        conversationState.renameConversation(conversation, to: title)
    }

    /// Filters conversations by title and message content via the store's indexed query,
    /// optionally scoped to a single agent. An empty/whitespace query returns all
    /// conversations (most-recent-first), matching the repository contract.
    func searchConversations(_ query: String, for agent: SavedAgent? = nil) -> [Conversation] {
        conversationState.searchConversations(query, for: agent)
    }

    // Asks the host to switch. The picker shows the mode as pending until mode_changed.
    func setMode(_ mode: ChatMode) {
        guard let conversation = activeConversation,
              conversation.mode != mode,
              pendingModeByConversationID[conversation.id] == nil else {
            return
        }
        let id = conversation.id
        pendingModeByConversationID[id] = mode
        Task {
            do {
                try await client.requestModeChange(
                    agentAddress: conversation.agentAddress,
                    conversation: conversation,
                    mode: mode.oipPermissionMode
                ) { [weak self] event in
                    self?.handleModeEvent(event, conversationID: id)
                }
            } catch {
                pendingModeByConversationID[id] = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleModeEvent(_ event: HostedAgentEvent, conversationID id: String) {
        pendingModeByConversationID[id] = nil
        switch event {
        case .modeChanged:
            deliveryCoordinator.apply(event, toConversationID: id)
        case .modeChangeFailed(let message):
            errorMessage = message
        case .modeChangeTimedOut:
            errorMessage = "The agent didn't confirm the mode change."
        default:
            break
        }
    }
}
