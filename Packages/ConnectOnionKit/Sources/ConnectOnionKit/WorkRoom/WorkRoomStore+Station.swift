import Foundation

/// Claude Station: pairing, the Station's Work Room, and handing Control between the terminal and this device.
extension WorkRoomStore {
    /// Where Pairing stands and whether it can be tried. Pairing needs only a transport: the host does not
    /// need session-sync for PROVIDER_* frames.
    public var stationPairing: StationPairing {
        StationPairing(state: pairingState, isConnected: isConnected, hasRememberedCode: rememberedCode != nil)
    }

    /// The agent is a Claude Station: its Work Room exists, or the host refused an outer INPUT or EXEC with
    /// `provider_station_only`. The app should not offer an ordinary chat to a Station.
    public var isStationHost: Bool {
        stationRefusal || stationWorkRoom != nil
    }

    /// Keeps the code entered for onboarding (the invite) and attaches with it by itself, once, as soon as
    /// the connection is ready. The code is kept in memory only and forgotten when it has been sent.
    public func rememberOnboardingCode(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        rememberedCode = code.isEmpty ? nil : code
        attachWithRememberedCode()
    }

    /// One automatic attach per remembered code, only when a CONNECTED has arrived and pairing can be tried.
    /// If it fails, the code is gone and the app asks for one (`stationPairing.needsCode`).
    func attachWithRememberedCode() {
        guard let code = rememberedCode, hasConnected, stationPairing.canPair else {
            return
        }
        rememberedCode = nil
        pairStation(code: code)
    }

    /// The Claude Station's Work Room, or nil until the host has sent a frame for it. It is the room an app
    /// shows directly when the Station row is selected.
    public var stationWorkRoom: WorkRoom? {
        workRooms.first { $0.isClaudeStation }
    }

    /// Sends the pairing code to the Station as a signed PROVIDER_STATION_ATTACH. Returns false, sending
    /// nothing, when pairing is unavailable (not offered, not connected, already pairing or paired), or the
    /// code is empty or too long. One attempt at a time; never retried.
    @discardableResult
    public func pairStation(code: String) -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = UUID().uuidString.lowercased()
        guard let transport, stationPairing.canPair,
              let frame = try? transport.frames.providerStationAttach(pairingCode: code, requestID: requestID) else {
            return false
        }
        attachRequestID = requestID
        pairingState = .pairing
        dispatch(frame, over: transport, timeout: StationPairingRules.acknowledgement) { store, why in
            store.failAttach(requestID, why == .timedOut ? StationPairingRules.timedOut : WorkRoomRequest.notSent)
        }
        return true
    }

    /// Only the single attach in flight, matched on `request_id`, can be answered. It needs `accepted` and a
    /// session id; anything else fails it with plain copy.
    func applyAttach(_ ack: OIPProviderStationAttachAck) {
        guard attachRequestID == ack.requestID else {
            return
        }
        guard ack.accepted else {
            failAttach(ack.requestID, StationPairingRules.rejectionText(reason: ack.reason))
            return
        }
        guard let sessionID = ack.sessionID, !sessionID.isEmpty else {
            failAttach(ack.requestID, StationPairingRules.noSession)
            return
        }
        attachRequestID = nil
        pairingState = .paired(sessionID: sessionID)
    }

    /// Ends the attach in flight with a reason. A stale timer, an unrelated ERROR or a late event is a no-op.
    func failAttach(_ requestID: String, _ text: String) {
        guard attachRequestID == requestID else {
            return
        }
        attachRequestID = nil
        pairingState = .failed(reason: text)
    }

    /// Asks the host to hand Control of the Station to this device (`take`) or back to the terminal (`release`),
    /// as a signed PROVIDER_CONTROL carrying the control revision and the paired session. Control does not
    /// change until the matching accepted ACK. Returns false, sending nothing, when there is no transport, paired
    /// session or positive control revision, a change is already in flight, the other side does not hold Control
    /// or is mid-handover, or the frame cannot be built. Session-sync is not needed: Core checks it only for
    /// SESSION_* frames. A take can wait about 10 s on the terminal. Never retried.
    @discardableResult
    public func changeControl(_ action: OIPProviderControlAction, in workRoomID: String) -> Bool {
        guard let transport,
              let control = workRoom(id: workRoomID)?.control,
              action == .take ? control.canTake : control.canRelease,
              let sessionID = stationPairing.sessionID,
              let invocation = invocations.first(where: { workRoomKey(of: $0) == workRoomID && $0.controlRevision != nil }),
              let revision = invocation.controlRevision, revision > 0,
              let frame = try? transport.frames.providerControl(
                  sessionID: sessionID, action: action, stateRevision: revision,
                  requestID: UUID().uuidString.lowercased()
              ),
              let requestID = frame["request_id"]?.stringValue else {
            return false
        }
        controlFailures[workRoomID] = nil
        controlChange = ControlRequest(
            requestID: requestID, workRoomID: workRoomID, invocationID: invocation.invocationID,
            action: action, revision: revision
        )
        dispatch(frame, over: transport, timeout: WorkRoomControlRules.acknowledgement) { store, why in
            store.failControl(requestID, why == .timedOut ? WorkRoomControlRules.timedOut : WorkRoomRequest.notSent)
        }
        return true
    }

    /// Only the single change in flight, matched on `request_id` (and on the action when the host names one),
    /// can be answered. Control moves only on `accepted` with a positive revision, and only if that revision
    /// is newer than the stored one: a `provider_session` that got here first already carries the newer state.
    func applyControl(_ ack: OIPProviderControlAck) {
        guard let request = controlChange, request.requestID == ack.requestID,
              ack.action.map({ $0.isEmpty || $0 == request.action.rawValue }) ?? true else {
            return
        }
        guard ack.accepted else {
            failControl(request.requestID, WorkRoomControlRules.rejectionText(reason: ack.reason))
            return
        }
        guard let revision = ack.stateRevision else {
            failControl(request.requestID, WorkRoomControlRules.unverified)
            return
        }
        controlChange = nil
        if request.action == .take {
            applyControl(request.invocationID, .browser, .remoteControlling, revision)
        } else {
            applyControl(request.invocationID, .browser, .handoverToLocal, revision)
        }
    }

    /// Ends the change in flight with a reason and leaves Control as it was. A stale timer or a late event is a no-op.
    func failControl(_ requestID: String, _ text: String) {
        guard let request = controlChange, request.requestID == requestID else {
            return
        }
        controlChange = nil
        controlFailures[request.workRoomID] = text
    }

    /// A fresh Station sends only `provider_session` until Claude's first hook. For a Station invocation not
    /// seen yet, that frame makes the Station's Work Room (Claude Code, the allowed title, no revision), which
    /// the later `provider_invocation` frames fill in.
    func applySession(_ session: OIPProviderSession) {
        let prefix = WorkRoom.stationIDPrefix
        if !invocations.contains(where: { $0.invocationID == session.invocationID }),
           session.invocationID.hasPrefix(prefix), session.invocationID.count > prefix.count {
            let parent = session.parentToolCallID
                ?? "claude_station:" + session.invocationID.dropFirst(prefix.count)
            var room = OIPProviderInvocation(
                invocationID: session.invocationID, parentToolCallID: parent, provider: .claudeCode
            )
            room.taskTitle = ProviderCopy.taskTitle("Claude Code session")
            apply(room)
        }
        applyControl(session.invocationID, session.owner, session.phase, session.stateRevision)
    }

    /// The control revision gate: a state whose revision is not newer than the stored one is dropped, which
    /// makes an equal one a no-op. The invocation must exist. Returns whether the state was applied.
    @discardableResult
    func applyControl(
        _ invocationID: String, _ owner: OIPControlOwner, _ phase: OIPControlPhase, _ revision: Int
    ) -> Bool {
        guard let index = invocations.firstIndex(where: { $0.invocationID == invocationID }),
              revision > invocations[index].controlRevision ?? 0 else {
            return false
        }
        invocations[index].controlOwner = owner
        invocations[index].controlPhase = phase
        invocations[index].controlRevision = revision
        return true
    }

    /// The Station's Control, from the member that carries a valid control triple.
    func control(id: String, members: [OIPProviderInvocation]) -> WorkRoomControl? {
        guard let holder = members.last(where: { $0.controlRevision != nil }),
              let owner = holder.controlOwner, let phase = holder.controlPhase else {
            return nil
        }
        var control = WorkRoomControl(owner: owner, phase: phase)
        control.pending = controlChange?.workRoomID == id ? controlChange?.action : nil
        control.failure = controlFailures[id]
        control.isConnected = isConnected
        control.isPaired = stationPairing.sessionID != nil
        return control
    }
}
