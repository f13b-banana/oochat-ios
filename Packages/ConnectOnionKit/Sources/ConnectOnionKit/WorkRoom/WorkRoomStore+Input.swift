import Foundation

/// Provider Input: the composer draft and the one message in flight.
extension WorkRoomStore {
    /// Keeps the text typed in a Work Room's composer. Ignored for an unknown Work Room and while its
    /// message is waiting for the host.
    public func setDraft(_ text: String, in workRoomID: String) {
        guard input?.workRoomID != workRoomID, pendingKey(inWorkRoom: workRoomID) != nil else {
            return
        }
        drafts[workRoomID] = text
    }

    /// Adds a finished transcription to the end of the Work Room's draft: trimmed, after one space when the draft
    /// already has text. Never sends and emits no frame. Text past the 12,000 character limit is kept, so nothing
    /// said is lost; the composer then shows the limit line and cannot send until it is shortened. Returns false,
    /// changing nothing, for blank text or when `setDraft` would ignore it. A failed transcription never calls this.
    @discardableResult
    public func appendDictation(_ text: String, in workRoomID: String) -> Bool {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, input?.workRoomID != workRoomID, pendingKey(inWorkRoom: workRoomID) != nil else {
            return false
        }
        let current = drafts[workRoomID] ?? ""
        let kept = String(current.reversed().drop(while: \.isWhitespace).reversed())
        drafts[workRoomID] = kept.isEmpty ? spoken : kept + " " + spoken
        return true
    }

    /// Sends the Work Room's draft to its current invocation (the latest continuation), trimmed, with the
    /// revision on screen, as a signed PROVIDER_INPUT. A finished invocation is allowed: the host starts a
    /// continuation. Returns false, sending nothing, when the composer is unavailable, the draft is empty or
    /// too long, or the frame cannot be built. Never retried.
    @discardableResult
    public func send(in workRoomID: String) -> Bool {
        guard let transport,
              let room = workRoom(id: workRoomID), room.composer.canSend,
              let current = pendingKey(inWorkRoom: workRoomID),
              let revision = invocations.first(where: { $0.invocationID == current })?.stateRevision,
              let frame = try? transport.frames.providerInput(
                  invocationID: current, requestID: UUID().uuidString.lowercased(),
                  stateRevision: revision, text: room.composer.draft
              ),
              let requestID = frame["requestId"]?.stringValue else {
            return false
        }
        inputRejections[workRoomID] = nil
        input = InputRequest(requestID: requestID, workRoomID: workRoomID, invocationID: current, revision: revision)
        dispatch(frame, over: transport, timeout: WorkRoomInputRules.acknowledgement) { store, why in
            store.failInput(requestID, why == .timedOut ? WorkRoomInputRules.timedOut : WorkRoomRequest.notSent)
        }
        return true
    }

    /// Only the single Input in flight, matched on request and invocation id, can be answered. The draft
    /// goes only when the ACK is accepted and echoes the revision sent.
    func applyInput(_ ack: OIPProviderAck) {
        guard let request = input, request.requestID == ack.requestID, request.invocationID == ack.invocationID else {
            return
        }
        guard ack.accepted else {
            failInput(request.requestID, WorkRoomInputRules.rejectionText(reason: ack.reason))
            return
        }
        guard ack.stateRevision == request.revision else {
            failInput(request.requestID, WorkRoomInputRules.unconfirmed)
            return
        }
        input = nil
        drafts[request.workRoomID] = nil
    }

    /// Ends the Input in flight with a reason and keeps the draft. A stale timer or a late event is a no-op.
    func failInput(_ requestID: String, _ text: String) {
        guard let request = input, request.requestID == requestID else {
            return
        }
        input = nil
        inputRejections[request.workRoomID] = text
    }

    func composer(
        id: String, current: OIPProviderInvocation, isDeciding: Bool, control: WorkRoomControl?
    ) -> WorkRoomComposer {
        var composer = WorkRoomComposer()
        composer.draft = drafts[id] ?? ""
        composer.rejection = inputRejections[id]
        composer.isSending = input?.workRoomID == id
        composer.isWaitingElsewhere = input != nil && !composer.isSending
        composer.isSupported = (current.stateRevision ?? 0) > 0
        composer.isStopping = stops[current.invocationID] != nil
        composer.isConnected = isConnected
        composer.isDeciding = isDeciding
        composer.controlReason = WorkRoomControlRules.composerReason(
            isStation: id.hasPrefix(WorkRoom.stationIDPrefix) && current.provider == .claudeCode, control: control
        )
        return composer
    }
}
