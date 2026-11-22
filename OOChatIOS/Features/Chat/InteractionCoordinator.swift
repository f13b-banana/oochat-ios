import Foundation

final class ContinuationGate<Decision>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: CheckedContinuation<Decision, Never>] = [:]
    private var isClosed = false
    private let cancellationDecision: Decision
    private let unavailableDecision: Decision

    init(cancellationDecision: Decision, unavailableDecision: Decision) {
        self.cancellationDecision = cancellationDecision
        self.unavailableDecision = unavailableDecision
    }

    @MainActor
    func wait(
        for id: String,
        present: () -> Bool,
        dismiss: () -> Void
    ) async -> Decision {
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled || isClosed {
                    lock.unlock()
                    continuation.resume(returning: cancellationDecision)
                    return
                }
                let replaced = continuations.updateValue(continuation, forKey: id)
                lock.unlock()
                replaced?.resume(returning: cancellationDecision)

                guard present() else {
                    resolve(id: id, with: unavailableDecision)
                    return
                }
            }
        } onCancel: {
            self.resolve(id: id, with: self.cancellationDecision)
        }
        dismiss()
        return decision
    }

    @discardableResult
    func resolve(id: String, with decision: Decision) -> Bool {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: decision)
        return continuation != nil
    }

    func cancelAll() {
        lock.lock()
        isClosed = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: cancellationDecision)
        }
    }

    deinit {
        cancelAll()
    }
}

@MainActor
final class InteractionCoordinator: ObservableObject {
    @Published private var interactionsByConversationID: [String: [HostedAgentInteraction]] = [:]

    private var supersededGateIDs: Set<String> = []
    /// A card appeared (interaction, conversationID), so the app can notify.
    var onPresented: ((HostedAgentInteraction, String) -> Void)?
    /// A card went away for any reason (answered, superseded, cancelled).
    var onDismissed: ((HostedAgentInteraction, String) -> Void)?

    private let approvalGate = ContinuationGate<ApprovalDecision>(
        cancellationDecision: .rejectHard(feedback: "Approval cancelled."),
        unavailableDecision: .rejectHard(feedback: "Approval unavailable.")
    )
    private let ulwCheckpointGate = ContinuationGate<UlwCheckpointDecision>(
        cancellationDecision: .switchMode(.safe),
        unavailableDecision: .switchMode(.safe)
    )
    private let planReviewGate = ContinuationGate<PlanReviewDecision>(
        cancellationDecision: .requestChanges(feedback: "Plan review cancelled."),
        unavailableDecision: .requestChanges(feedback: "Plan review unavailable.")
    )
    private let askUserGate = ContinuationGate<AskUserDecision>(
        cancellationDecision: .cancel,
        unavailableDecision: .cancel
    )

    func handle(
        _ interaction: HostedAgentInteraction,
        conversationID: String,
        isConversationAvailable: () -> Bool
    ) async -> HostedAgentInteractionDecision {
        let gateID = Self.gateID(conversationID: conversationID, interaction: interaction)
        switch interaction {
        case .approval:
            let decision = await approvalGate.wait(for: gateID) {
                self.present(interaction, conversationID: conversationID, isConversationAvailable: isConversationAvailable)
            } dismiss: {
                self.dismiss(interaction, conversationID: conversationID)
            }
            return consumeSuperseded(gateID) ? .superseded : .approval(decision)
        case .ulwCheckpoint:
            let decision = await ulwCheckpointGate.wait(for: gateID) {
                self.present(interaction, conversationID: conversationID, isConversationAvailable: isConversationAvailable)
            } dismiss: {
                self.dismiss(interaction, conversationID: conversationID)
            }
            return consumeSuperseded(gateID) ? .superseded : .ulwCheckpoint(decision)
        case .planReview:
            let decision = await planReviewGate.wait(for: gateID) {
                self.present(interaction, conversationID: conversationID, isConversationAvailable: isConversationAvailable)
            } dismiss: {
                self.dismiss(interaction, conversationID: conversationID)
            }
            return consumeSuperseded(gateID) ? .superseded : .planReview(decision)
        case .askUser:
            let decision = await askUserGate.wait(for: gateID) {
                self.present(interaction, conversationID: conversationID, isConversationAvailable: isConversationAvailable)
            } dismiss: {
                self.dismiss(interaction, conversationID: conversationID)
            }
            return consumeSuperseded(gateID) ? .superseded : .askUser(decision)
        }
    }

    func pendingApproval(for conversationID: String?) -> PendingApproval? {
        guard let conversationID,
              case .approval(let request)? = interaction(of: .approval, for: conversationID) else {
            return nil
        }
        return PendingApproval(conversationID: conversationID, request: request)
    }

    func pendingUlwCheckpoint(for conversationID: String?) -> PendingUlwCheckpoint? {
        guard let conversationID,
              case .ulwCheckpoint(let request)? = interaction(of: .ulwCheckpoint, for: conversationID) else {
            return nil
        }
        return PendingUlwCheckpoint(conversationID: conversationID, request: request)
    }

    func pendingPlanReview(for conversationID: String?) -> PendingPlanReview? {
        guard let conversationID,
              case .planReview(let request)? = interaction(of: .planReview, for: conversationID) else {
            return nil
        }
        return PendingPlanReview(conversationID: conversationID, request: request)
    }

    func pendingAskUser(for conversationID: String?) -> PendingAskUser? {
        guard let conversationID,
              case .askUser(let request)? = interaction(of: .askUser, for: conversationID) else {
            return nil
        }
        return PendingAskUser(conversationID: conversationID, request: request)
    }

    func pendingInteractionID(for conversationID: String?) -> String? {
        pendingApproval(for: conversationID)?.id
            ?? pendingUlwCheckpoint(for: conversationID)?.id
            ?? pendingPlanReview(for: conversationID)?.id
            ?? pendingAskUser(for: conversationID)?.id
    }

    func hasPendingInteraction(for conversationID: String) -> Bool {
        !(interactionsByConversationID[conversationID] ?? []).isEmpty
    }

    /// A tool approval specifically, as opposed to a question, plan or checkpoint to answer.
    func hasPendingApproval(for conversationID: String) -> Bool {
        (interactionsByConversationID[conversationID] ?? []).contains {
            if case .approval = $0 { return true }
            return false
        }
    }

    func hasPendingInteraction(excluding conversationID: String?) -> Bool {
        interactionsByConversationID.contains { key, interactions in
            key != conversationID && !interactions.isEmpty
        }
    }

    @discardableResult
    func resolve(
        id: String,
        conversationID: String?,
        with decision: HostedAgentInteractionDecision
    ) -> Bool {
        guard let conversationID,
              let interaction = interactionsByConversationID[conversationID]?.first(where: {
                  $0.id == id && $0.accepts(decision)
              }) else {
            return false
        }
        dismiss(interaction, conversationID: conversationID)
        let gateID = Self.gateID(conversationID: conversationID, interaction: interaction)
        switch decision {
        case .approval(let value):
            return approvalGate.resolve(id: gateID, with: value)
        case .ulwCheckpoint(let value):
            return ulwCheckpointGate.resolve(id: gateID, with: value)
        case .planReview(let value):
            return planReviewGate.resolve(id: gateID, with: value)
        case .askUser(let value):
            return askUserGate.resolve(id: gateID, with: value)
        case .superseded:
            // Only the coordinator produces this, never the UI.
            return false
        }
    }

    @discardableResult
    func cancelInteractions(for conversationID: String) -> Bool {
        guard let interactions = interactionsByConversationID.removeValue(forKey: conversationID),
              !interactions.isEmpty else {
            return false
        }
        for interaction in interactions {
            let gateID = Self.gateID(conversationID: conversationID, interaction: interaction)
            switch interaction {
            case .approval:
                approvalGate.resolve(
                    id: gateID,
                    with: .rejectHard(feedback: "Approval cancelled.")
                )
            case .ulwCheckpoint:
                ulwCheckpointGate.resolve(id: gateID, with: .switchMode(.safe))
            case .planReview:
                planReviewGate.resolve(
                    id: gateID,
                    with: .requestChanges(feedback: "Plan review cancelled.")
                )
            case .askUser:
                askUserGate.resolve(id: gateID, with: .cancel)
            }
        }
        return true
    }

    func cancelAll() {
        interactionsByConversationID.removeAll()
        supersededGateIDs.removeAll()
        approvalGate.cancelAll()
        ulwCheckpointGate.cancelAll()
        planReviewGate.cancelAll()
        askUserGate.cancelAll()
    }

    private func present(
        _ interaction: HostedAgentInteraction,
        conversationID: String,
        isConversationAvailable: () -> Bool
    ) -> Bool {
        guard isConversationAvailable() else {
            return false
        }
        var interactions = interactionsByConversationID[conversationID] ?? []
        // A server that sends a second request of the same kind supersedes the first card.
        // Its gate has to be resolved too, or the connection's receive loop stays blocked
        // forever and the conversation can never be stopped.
        let superseded = interactions.filter {
            $0.kind == interaction.kind && $0.id != interaction.id
        }
        interactions.removeAll { $0.kind == interaction.kind }
        interactions.append(interaction)
        interactionsByConversationID[conversationID] = interactions
        for old in superseded {
            resolveSuperseded(old, conversationID: conversationID)
        }
        onPresented?(interaction, conversationID)
        return true
    }

    /// Releases the gate of a request the agent replaced with a newer one of the same kind.
    /// The gate value itself is discarded: `handle` sees the gate ID in `supersededGateIDs`
    /// and reports `.superseded`, so nothing is written back to a request the agent has
    /// already moved on from. Without this the receive loop would stay blocked forever.
    private func resolveSuperseded(_ interaction: HostedAgentInteraction, conversationID: String) {
        let gateID = Self.gateID(conversationID: conversationID, interaction: interaction)
        supersededGateIDs.insert(gateID)
        switch interaction {
        case .approval:
            approvalGate.resolve(id: gateID, with: .rejectHard(feedback: "Superseded by a newer request."))
        case .ulwCheckpoint:
            ulwCheckpointGate.resolve(id: gateID, with: .switchMode(.safe))
        case .planReview:
            planReviewGate.resolve(id: gateID, with: .requestChanges(feedback: "Superseded by a newer request."))
        case .askUser:
            askUserGate.resolve(id: gateID, with: .cancel)
        }
    }

    private func consumeSuperseded(_ gateID: String) -> Bool {
        supersededGateIDs.remove(gateID) != nil
    }

    private func dismiss(_ interaction: HostedAgentInteraction, conversationID: String) {
        guard var interactions = interactionsByConversationID[conversationID] else {
            return
        }
        interactions.removeAll { $0.kind == interaction.kind && $0.id == interaction.id }
        if interactions.isEmpty {
            interactionsByConversationID[conversationID] = nil
        } else {
            interactionsByConversationID[conversationID] = interactions
        }
        onDismissed?(interaction, conversationID)
    }

    private func interaction(
        of kind: HostedAgentInteraction.Kind,
        for conversationID: String
    ) -> HostedAgentInteraction? {
        interactionsByConversationID[conversationID]?.first { $0.kind == kind }
    }

    private static func gateID(
        conversationID: String,
        interaction: HostedAgentInteraction
    ) -> String {
        "\(conversationID)::\(interaction.kind.rawValue)::\(interaction.id)"
    }
}

private extension HostedAgentInteraction {
    enum Kind: String {
        case approval
        case ulwCheckpoint
        case planReview
        case askUser
    }

    var kind: Kind {
        switch self {
        case .approval:
            return .approval
        case .ulwCheckpoint:
            return .ulwCheckpoint
        case .planReview:
            return .planReview
        case .askUser:
            return .askUser
        }
    }

    func accepts(_ decision: HostedAgentInteractionDecision) -> Bool {
        switch (self, decision) {
        case (.approval, .approval),
             (.ulwCheckpoint, .ulwCheckpoint),
             (.planReview, .planReview),
             (.askUser, .askUser):
            return true
        default:
            return false
        }
    }
}
