import Foundation

/// The Permission Profile selector and the one profile change in flight.
extension WorkRoomStore {
    /// Asks the host to switch the Work Room's current invocation to another Permission Profile, with the
    /// revision on screen, as a signed PROVIDER_PERMISSION_CHANGE. The label keeps the old profile until the
    /// host confirms. Returns false, sending nothing, when there is no transport, a change is already in
    /// flight, the current invocation has no revision or the group has no valid catalog, the option is
    /// unknown, not selectable or already active, an elevated option lacks `confirmRisk`, or the frame cannot be built.
    @discardableResult
    public func changePermission(to optionID: String, confirmRisk: Bool, in workRoomID: String) -> Bool {
        let members = invocations.filter { workRoomKey(of: $0) == workRoomID }
        guard let transport, permissionChange == nil,
              let invocation = currentInvocation(of: members), case let current = invocation.invocationID,
              let revision = invocation.stateRevision,
              let catalog = permissionCatalog(current: invocation, members: members),
              let option = catalog.options.first(where: { $0.id == optionID }),
              option.isSelectable, option.id != catalog.activeOptionID,
              option.risk != .elevated || confirmRisk,
              let frame = try? transport.frames.providerPermissionChange(
                  invocationID: current, requestID: UUID().uuidString.lowercased(), stateRevision: revision,
                  optionID: option.id, confirmRisk: option.risk == .elevated
              ),
              let requestID = frame["requestId"]?.stringValue else {
            return false
        }
        permissionFailures[workRoomID] = nil
        permissionChange = PermissionRequest(
            requestID: requestID, workRoomID: workRoomID, invocationID: current, revision: revision, optionID: option.id
        )
        dispatch(frame, over: transport, timeout: WorkRoomPermissionTiming.acknowledgement) { store, why in
            store.failPermission(requestID, why == .timedOut ? WorkRoomPermission.timedOut : WorkRoomRequest.notSent)
        }
        return true
    }

    /// Only the single change in flight, matched on request and invocation id, can be answered. It is applied
    /// only when accepted with a strictly newer revision and a catalog that validates at that revision and
    /// has the requested option active. Then the invocation's revision and catalog are updated in place, and
    /// the host's equal-revision `provider_invocation` that follows is a no-op. Anything else keeps the old
    /// profile.
    func applyPermission(_ ack: OIPProviderAck) {
        guard let request = permissionChange, request.requestID == ack.requestID,
              request.invocationID == ack.invocationID else {
            return
        }
        guard ack.accepted else {
            failPermission(request.requestID, WorkRoomPermission.rejectionText(reason: ack.reason))
            return
        }
        guard let revision = ack.stateRevision, revision > request.revision,
              let index = invocations.firstIndex(where: { $0.invocationID == request.invocationID }),
              let catalog = OIPProviderPermission(
                  ack.providerPermission, provider: invocations[index].provider, stateRevision: revision
              ),
              catalog.activeOptionID == request.optionID else {
            failPermission(request.requestID, WorkRoomPermission.unverified)
            return
        }
        permissionChange = nil
        // A newer frame may have arrived while waiting; it already carries the newer state.
        if revision > (invocations[index].stateRevision ?? 0) {
            invocations[index].stateRevision = revision
            invocations[index].providerPermission = catalog
        }
    }

    /// Ends the change in flight with a reason and keeps the old profile. A stale timer or a late event is a no-op.
    func failPermission(_ requestID: String, _ text: String) {
        guard let request = permissionChange, request.requestID == requestID else {
            return
        }
        permissionChange = nil
        permissionFailures[request.workRoomID] = WorkRoomPermission.Failure(optionID: request.optionID, text: text)
    }

    /// The current invocation's catalog, or the newest valid one from the same Provider in the group when it
    /// has none (a finished invocation whose last frame carried no catalog).
    func permissionCatalog(current: OIPProviderInvocation, members: [OIPProviderInvocation]) -> OIPProviderPermission? {
        current.providerPermission ?? members.last {
            $0.provider == current.provider && $0.providerPermission != nil
        }?.providerPermission
    }

    /// A change targets the current invocation at its current revision, so it can be sent whenever that
    /// invocation has a revision, with the choices of the catalog above.
    func permission(id: String, current: OIPProviderInvocation, members: [OIPProviderInvocation]) -> WorkRoomPermission? {
        // A Station answers a profile change with `unsupported_option`, so it has no selector.
        guard !(id.hasPrefix(WorkRoom.stationIDPrefix) && current.provider == .claudeCode),
              let catalog = permissionCatalog(current: current, members: members) else {
            return nil
        }
        var permission = WorkRoomPermission(catalog: catalog, isCurrent: current.stateRevision != nil)
        permission.isConnected = isConnected
        permission.pendingID = permissionChange?.workRoomID == id ? permissionChange?.optionID : nil
        permission.isWaitingElsewhere = permissionChange != nil && permission.pendingID == nil
        permission.failure = permissionFailures[id]
        return permission
    }
}
