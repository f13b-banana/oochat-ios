import ConnectOnionKit

extension ChatViewModel {
    func allowPendingApprovalOnce(id: String) {
        resolvePendingApproval(id: id, with: .allowOnce)
    }

    func trustPendingApprovalForSession(id: String) {
        resolvePendingApproval(id: id, with: .allowSession)
    }

    func skipPendingApproval(id: String) {
        markToolAwaitingApproval(id: id, as: .skipped)
        resolvePendingApproval(id: id, with: .rejectSoft(feedback: nil))
    }

    func stopPendingApproval(id: String) {
        resolvePendingApproval(id: id, with: .rejectHard(feedback: nil))
    }

    func explainPendingApproval(id: String) {
        resolvePendingApproval(id: id, with: .rejectExplain(feedback: nil))
    }

    func continueUlw(id: String, turns: Int = UlwCheckpointDecision.continueTurns) {
        resolvePendingUlwCheckpoint(id: id, with: .continueWork(turns: turns))
    }

    func switchModeFromUlwCheckpoint(id: String, to mode: ChatMode) {
        guard activePendingUlwCheckpoint?.id == id else {
            return
        }
        setMode(mode)
        resolvePendingUlwCheckpoint(id: id, with: .switchMode(mode))
    }

    func approvePendingPlan(id: String) {
        resolvePendingPlanReview(id: id, with: .approve)
    }

    func requestPlanChanges(id: String, feedback: String?) {
        resolvePendingPlanReview(id: id, with: .requestChanges(feedback: feedback))
    }

    func discardPendingPlan(id: String) {
        resolvePendingPlanReview(id: id, with: .discard)
        // The reply asks the agent to return to Safe mode. Ask the host to switch as well, so the
        // mode menu doesn't stay on plan mode after the plan is gone.
        if activeMode == .plan {
            setMode(.safe)
        }
    }

    func answerPendingAskUser(id: String, answer: String) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .askUser(.answer(answer))
        )
    }

    /// What a tool row shows: a running tool whose approval card is open is waiting on you.
    func toolRowState(for message: ChatMessage, in conversationID: String) -> ToolRowState {
        if isToolCallCoveredByPendingApproval(message, in: conversationID) {
            return .awaitingApproval
        }
        return (message.toolState ?? .running).rowState
    }

    /// The tool the open approval card asks about, if it's in this chat.
    func toolAwaitingApprovalID(in conversationID: String) -> String? {
        conversation(withID: conversationID)?.messages
            .first { isToolCallCoveredByPendingApproval($0, in: conversationID) }?
            .id
    }

    /// Settles the tool the open approval card asks about, before the answer goes out.
    private func markToolAwaitingApproval(id: String, as state: ToolCallState) {
        guard activePendingApproval?.id == id,
              var conversation = activeConversation,
              let index = conversation.messages.firstIndex(where: {
                  isToolCallCoveredByPendingApproval($0, in: conversation.id)
              }) else {
            return
        }
        conversation.messages[index].toolState = state
        upsert(conversation)
    }

    private func resolvePendingApproval(id: String, with decision: ApprovalDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .approval(decision)
        )
    }

    private func resolvePendingUlwCheckpoint(id: String, with decision: UlwCheckpointDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .ulwCheckpoint(decision)
        )
    }

    private func resolvePendingPlanReview(id: String, with decision: PlanReviewDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .planReview(decision)
        )
    }

    func cancelPendingInteractions(forConversationID conversationID: String) {
        deliveryCoordinator.cancelDeliveryAndInteractions(for: conversationID)
    }
}
