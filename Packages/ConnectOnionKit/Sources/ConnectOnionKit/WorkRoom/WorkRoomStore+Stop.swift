import Foundation

/// The Scoped Stop and its barrier, saved per session so a pending Stop survives a relaunch.
extension WorkRoomStore {
    /// Removes the Stop Barrier saved for a chat that was deleted, so it does not stay in storage for good.
    /// `scope` is the one the chat's store was made with. Nothing happens when none was saved, and other
    /// chats' barriers are left alone.
    public nonisolated static func forgetBarrier(
        scope: String,
        storage: WorkRoomBarrierStorage = UserDefaults.standard
    ) {
        storage.removeObject(forKey: WorkRoomBarrierStore.key(scope: scope))
    }

    /// Asks the host to stop the Work Room's current Provider Invocation, with the revision on screen.
    /// Returns false, sending nothing, when there is no transport, the invocation is finished or has no
    /// positive revision, a Stop is already in flight or held, or the frame cannot be built.
    @discardableResult
    public func stop(in workRoomID: String) -> Bool {
        guard let transport,
              !stops.values.contains(where: { $0.phase == .requesting }),
              let current = pendingKey(inWorkRoom: workRoomID),
              stops[current] == nil,
              let invocation = invocations.first(where: { $0.invocationID == current }),
              invocation.status?.isTerminal != true,
              let revision = invocation.stateRevision, revision > 0 else {
            return false
        }
        let requestID = UUID().uuidString.lowercased()
        guard let frame = try? transport.frames.providerInterrupt(
            invocationID: current, requestID: requestID, stateRevision: revision
        ) else {
            return false
        }
        stopRejections[current] = nil
        stops[current] = StopRequest(requestID: requestID, revision: revision, phase: .requesting, expiresAt: nil)
        // Fails closed either way: a Stop that may have gone out needs confirmation.
        dispatch(frame, over: transport, timeout: WorkRoomStopTiming.acknowledgement) { store, _ in
            store.failStop(requestID)
        }
        return true
    }

    /// Only the single request in flight, matched on request and invocation id, can be answered.
    func apply(_ ack: OIPProviderAck) {
        guard let key = ack.invocationID, let request = stops[key],
              request.phase == .requesting, request.requestID == ack.requestID else {
            return
        }
        guard ack.accepted else {
            stops[key] = nil
            stopRejections[key] = WorkRoomStop.rejectionText(reason: ack.reason)
            return
        }
        // The host forwarded the stop but did not echo the revision sent: the outcome is unknown.
        guard let revision = request.revision, ack.stateRevision == revision else {
            holdBarrier(key, .unconfirmed)
            return
        }
        stops[key]?.expiresAt = now().addingTimeInterval(WorkRoomStopTiming.terminalEvent.seconds)
        holdBarrier(key, .acknowledged)
        schedule(WorkRoomStopTiming.terminalEvent) { [weak self] in
            self?.expireStop(key, request.requestID, from: .acknowledged)
        }
    }

    /// An ERROR with the request id of a Stop still waiting. The host did not say what it did with the Stop, so it
    /// fails closed like a missing ACK: the run needs confirmation. Any other request id is a no-op.
    func failStop(_ requestID: String) {
        for (key, request) in stops where request.phase == .requesting && request.requestID == requestID {
            holdBarrier(key, .unconfirmed)
        }
    }

    /// Hides the approval and the Stop control until a terminal event or a newer revision.
    func holdBarrier(_ key: String, _ phase: WorkRoomStop.Phase) {
        stops[key]?.phase = phase
        pendingApprovals[key] = nil
    }

    func expireStop(_ key: String, _ requestID: String, from phase: WorkRoomStop.Phase) {
        if let request = stops[key], request.requestID == requestID, request.phase == phase {
            holdBarrier(key, .unconfirmed)
        }
    }

    /// A first sight of an invocation: a saved barrier is released by its end or a newer revision, and when
    /// the saved barrier was not trusted every unfinished invocation starts as needing confirmation.
    func meetBarrier(of invocation: OIPProviderInvocation) {
        let key = invocation.invocationID
        if let request = stops[key] {
            if invocation.status?.isTerminal == true
                || request.revision.map({ (invocation.stateRevision ?? 0) > $0 }) == true {
                stops[key] = nil
            }
        } else if barrierUntrusted, invocation.status?.isTerminal != true {
            stops[key] = StopRequest(
                requestID: UUID().uuidString.lowercased(), revision: invocation.stateRevision ?? 0,
                phase: .unconfirmed, expiresAt: nil
            )
        }
    }

    /// Saves the Stop Barrier under another scope from now on and removes it from the old one, for a store
    /// that now serves another session. nil keeps it in memory only.
    public func moveBarrier(toScope scope: String?) {
        if let barrierKey {
            barrierStorage.removeObject(forKey: barrierKey)
        }
        barrierKey = scope.map(WorkRoomBarrierStore.key(scope:))
        saveBarrier()
    }

    func saveBarrier() {
        guard let barrierKey else {
            return
        }
        let entries = stops.map { key, request in
            StoredStopBarrier(
                invocationId: key, stateRevision: request.revision,
                phase: request.phase == .requesting ? "requesting" : request.phase == .acknowledged ? "acknowledged" : "unconfirmed",
                expiresAt: request.expiresAt?.timeIntervalSince1970
            )
        }
        WorkRoomBarrierStore.save(entries, to: barrierStorage, key: barrierKey)
    }

    /// A Stop that was in flight is unknown after a relaunch, and an acknowledged one is trusted only for
    /// the time it had left. Storage that cannot be read marks every invocation seen later.
    func restoreBarrier() {
        guard let barrierKey else {
            return
        }
        guard let entries = WorkRoomBarrierStore.load(from: barrierStorage, key: barrierKey) else {
            barrierUntrusted = true
            return
        }
        for entry in entries {
            let revision = entry.stateRevision.flatMap { $0 > 0 ? $0 : nil }
            var request = StopRequest(
                requestID: UUID().uuidString.lowercased(), revision: revision, phase: .unconfirmed, expiresAt: nil
            )
            if entry.phase == "acknowledged", revision != nil, let expiry = entry.expiresAt {
                let remaining = Date(timeIntervalSince1970: expiry).timeIntervalSince(now())
                if remaining > 0 {
                    request.phase = .acknowledged
                    request.expiresAt = Date(timeIntervalSince1970: expiry)
                    let (key, requestID) = (entry.invocationId, request.requestID)
                    schedule(.seconds(remaining)) { [weak self] in
                        self?.expireStop(key, requestID, from: .acknowledged)
                    }
                }
            }
            stops[entry.invocationId] = request
        }
        saveBarrier()
    }

    func stop(for invocation: OIPProviderInvocation, status: OIPProviderStatus) -> WorkRoomStop {
        var stop = WorkRoomStop()
        stop.phase = stops[invocation.invocationID]?.phase ?? .idle
        stop.rejection = stopRejections[invocation.invocationID]
        stop.isActive = !status.isTerminal && (invocation.stateRevision ?? 0) > 0
        stop.isConnected = isConnected
        return stop
    }
}
