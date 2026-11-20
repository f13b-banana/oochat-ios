import Foundation

/// Provider approvals: which `approval_needed` the store owns, and the one answer a decision sends.
extension WorkRoomStore {
    /// True for an `approval_needed` body that is a verified Provider approval for an invocation the store
    /// knows, whether or not it is still pending, settled or finished. The app keeps such a frame off the
    /// outer approval card, so it is answered only through `decide`. It depends only on the frame and the
    /// known invocations, so it gives the same answer before or after `receive`, and for a frame without
    /// an `id`. Call it after the invocation's `provider_invocation` has been received; an unverified or
    /// unmatched approval is not owned and stays with the outer card.
    public func ownsApproval(_ body: [String: JSONValue]) -> Bool {
        guard let approval = OIPProviderApproval(body), approval.presentation != nil else {
            return false
        }
        return isKnown(approval.invocationID, approval.parentToolCallID, approval.provider)
    }

    /// Answers the Work Room's pending Provider approval and settles it for the card and the Work Room
    /// at once. Sends exactly one APPROVAL_RESPONSE through `transport`. Returns false, changing nothing,
    /// when there is nothing to decide, the decision is not offered, or the frame cannot be built or sent.
    @discardableResult
    public func decide(_ decision: WorkRoomDecision, in workRoomID: String) -> Bool {
        guard let transport,
              let approval = workRoom(id: workRoomID)?.approval,
              decision == .reject ? approval.offersReject : approval.offersAllow,
              let key = pendingKey(inWorkRoom: workRoomID),
              let pending = pendingApprovals[key],
              let frame = try? transport.frames.approvalResponse(
                requestID: pending.approval.id,
                decision: Self.decisionFields(decision)
              ) else {
            return false
        }
        settle(key, .settled(decision))
        transport.send(frame) { [weak self] in
            self?.reopen(key, pending.approval, after: decision)
        }
        return true
    }

    /// Only an approval for a known, unfinished invocation is kept, and the newest overwrites the Work
    /// Room's older one. A frame for an unknown invocation is ignored, not buffered.
    func apply(_ approval: OIPProviderApproval) {
        guard let invocation = invocations.first(where: {
            $0.invocationID == approval.invocationID
                && $0.parentToolCallID == approval.parentToolCallID
                && $0.provider == approval.provider
        }), invocation.status?.isTerminal != true,
              stops[invocation.invocationID].map({ $0.phase == .requesting }) ?? true,
              !answeredApprovals.contains(Self.answeredKey(approval)) else {
            return
        }
        let key = workRoomKey(of: invocation)
        for other in invocations where workRoomKey(of: other) == key {
            pendingApprovals[other.invocationID] = nil
        }
        pendingApprovals[approval.invocationID] = PendingApproval(approval: approval)
    }

    func markAnsweredElsewhere(requestID: String?) {
        for (key, pending) in pendingApprovals where pending.approval.id == requestID {
            settle(key, .answeredElsewhere)
        }
    }

    /// The decision could not be sent, so the approval is open again, unless something newer replaced or settled it.
    func reopen(_ key: String, _ approval: OIPProviderApproval, after decision: WorkRoomDecision) {
        guard var pending = pendingApprovals[key], pending.approval.id == approval.id,
              pending.phase == .settled(decision) else {
            return
        }
        pending.phase = .pending
        pendingApprovals[key] = pending
        answeredApprovals.remove(Self.answeredKey(approval))
    }

    /// A settled or answered-elsewhere approval never goes back to pending, except when its answer was not sent.
    func settle(_ key: String, _ phase: WorkRoomApproval.Phase) {
        guard var pending = pendingApprovals[key] else {
            return
        }
        pending.phase = phase
        pendingApprovals[key] = pending
        answeredApprovals.insert(Self.answeredKey(pending.approval))
    }

    static func answeredKey(_ approval: OIPProviderApproval) -> String {
        "\(approval.invocationID)\n\(approval.id ?? "")"
    }

    static func decisionFields(_ decision: WorkRoomDecision) -> [String: JSONValue] {
        switch decision {
        case .allowOnce:
            ["approved": .bool(true), "scope": .string("once")]
        case .reject:
            ["approved": .bool(false), "scope": .string("once"), "mode": .string("reject_hard")]
        }
    }

    func approval(for invocation: OIPProviderInvocation, status: OIPProviderStatus) -> WorkRoomApproval? {
        // Kept in memory while a Stop exists, so a refused Stop brings it back; never offered meanwhile.
        guard stops[invocation.invocationID] == nil,
              let pending = pendingApprovals[invocation.invocationID],
              let shown = pending.approval.presentation else {
            return nil
        }
        return WorkRoomApproval(
            id: pending.approval.id,
            action: shown.action,
            scope: shown.scopeText,
            reason: shown.reason,
            classification: shown.scope,
            files: shown.files,
            phase: pending.phase,
            allowOnce: shown.allowOnce,
            isAwaitingApproval: status == .awaitingApproval
        )
    }
}
