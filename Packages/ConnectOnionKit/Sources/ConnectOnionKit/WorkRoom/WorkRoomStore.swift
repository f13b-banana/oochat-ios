import Foundation
import Observation
/// One per agent session, and the only place Provider frames are interpreted: feed it every
/// decoded server frame and read the Work Rooms it keeps. Frames that break a rule are dropped.
@MainActor
@Observable
public final class WorkRoomStore {
    /// In arrival order, which is transcript order.
    var invocations: [OIPProviderInvocation] = []
    var activities: [String: [OIPProviderActivity]] = [:]
    /// In arrival order across every invocation, so a group's conversation reads as it happened.
    var messages: [OIPProviderMessage] = []
    /// At most one per Work Room, keyed by the invocation it waits on.
    var pendingApprovals: [String: PendingApproval] = [:]
    /// Approvals already answered, by invocation and id, so a replayed frame cannot reopen one.
    var answeredApprovals: Set<String> = []

    /// Scoped Stops that have not finished, by invocation. Saved under the barrier scope on every change.
    var stops: [String: StopRequest] = [:] {
        didSet { saveBarrier() }
    }
    /// The saved barrier could not be trusted: each live invocation needs confirmation until it has a newer
    /// revision or ends.
    var barrierUntrusted = false
    /// Why the host last refused a Stop, by invocation.
    var stopRejections: [String: String] = [:]
    /// Drafts for Provider Input, by Work Room. Cleared only by an accepted, confirmed send.
    var drafts: [String: String] = [:]
    /// Why the host last did not accept a message, by Work Room.
    var inputRejections: [String: String] = [:]
    /// The one Provider Input waiting for its answer, in any Work Room.
    var input: InputRequest?
    /// The one Permission Profile change waiting for its answer, in any Work Room.
    var permissionChange: PermissionRequest?
    /// Why the host last did not accept a profile change, by Work Room.
    var permissionFailures: [String: WorkRoomPermission.Failure] = [:]
    /// Where Pairing with the Claude Station stands. In memory only; it survives a dropped connection.
    var pairingState = StationPairing.State.unpaired
    /// The code the person entered for onboarding, kept until the automatic attach uses it.
    var rememberedCode: String?
    /// A CONNECTED arrived on the current connection, so the host is ready for PROVIDER_* frames.
    var hasConnected = false
    /// The host answered an outer INPUT or EXEC with `provider_station_only`.
    var stationRefusal = false
    /// At most one screenshot per invocation, kept only while its revision is the invocation's current one.
    var previews: [String: OIPProviderArtifact.Screenshot] = [:]
    /// The one PROVIDER_STATION_ATTACH waiting for its answer.
    var attachRequestID: String?
    /// The one PROVIDER_CONTROL waiting for its answer.
    var controlChange: ControlRequest?
    /// Why the host last did not change Control, by Work Room.
    var controlFailures: [String: String] = [:]
    @ObservationIgnored let schedule: WorkRoomScheduler
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let barrierStorage: WorkRoomBarrierStorage
    @ObservationIgnored var barrierKey: String?

    struct InputRequest {
        let requestID: String
        let workRoomID: String
        let invocationID: String
        let revision: Int
    }

    struct PermissionRequest {
        let requestID: String
        let workRoomID: String
        let invocationID: String
        let revision: Int
        let optionID: String
    }

    struct ControlRequest {
        let requestID: String
        let workRoomID: String
        let invocationID: String
        let action: OIPProviderControlAction
        let revision: Int
    }

    struct StopRequest {
        let requestID: String
        /// The revision the Stop was sent or acknowledged against; nil when a saved barrier lost it, so only an
        /// end releases it.
        let revision: Int?
        var phase: WorkRoomStop.Phase
        /// When an acknowledged Stop stops being trusted.
        var expiresAt: Date?
    }

    struct PendingApproval {
        let approval: OIPProviderApproval
        var phase: WorkRoomApproval.Phase = .pending
    }

    /// Where signed client frames go. The app sets it while its socket is ready; with none, a decision
    /// is refused and stays open.
    @ObservationIgnored public var transport: WorkRoomTransport? {
        didSet {
            isConnected = transport != nil
            attachWithRememberedCode()
        }
    }

    /// Whether `transport` is set. Observed, so a Work Room redraws when the connection comes or goes.
    var isConnected = false

    /// `barrierScope` names the session the Stop Barrier is saved for (the app passes the agent address and
    /// the session id, for example "<address>:<session id>"); nil keeps the barrier in memory only. Saved
    /// barriers are restored here, fail closed.
    public init(
        schedule: @escaping WorkRoomScheduler = WorkRoomStore.sleepThenRun,
        barrierScope: String? = nil,
        barrierStorage: WorkRoomBarrierStorage = UserDefaults.standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.schedule = schedule
        self.now = now
        self.barrierStorage = barrierStorage
        barrierKey = barrierScope.map(WorkRoomBarrierStore.key(scope:))
        restoreBarrier()
    }

    /// One Work Room per group, in the order each group first appeared.
    public var workRooms: [WorkRoom] {
        var order: [String] = []
        var groups: [String: [OIPProviderInvocation]] = [:]
        for invocation in invocations {
            let key = workRoomKey(of: invocation)
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(invocation)
        }
        return order.compactMap { key in groups[key].flatMap { workRoom(id: key, members: $0) } }
    }

    /// The Work Room with this group key, for the app to show while it stays open.
    public func workRoom(id: String) -> WorkRoom? {
        workRooms.first { $0.id == id }
    }

    /// The Work Room whose card replaces the outer `tool_call` with this id. Only a group's root
    /// has a card, so a continuation's tool call gives nil.
    public func workRoom(forToolCallID toolCallID: String) -> WorkRoom? {
        workRooms.first { $0.toolCallID == toolCallID }
    }

    /// True when a Provider Invocation replaces this outer `tool_call`, so the timeline should
    /// not draw it as an ordinary tool call. This includes continuations, which have no card.
    public func isProviderToolCall(_ toolCallID: String) -> Bool {
        invocations.contains { $0.parentToolCallID == toolCallID }
    }

    /// The `type` of every frame `receive` acts on, so an app can hand the store only these.
    public nonisolated static let frameTypes: Set<String> = [
        OIPFrameType.providerInvocation, OIPFrameType.providerActivity, OIPFrameType.providerMessage,
        OIPFrameType.providerInterruptAck, OIPFrameType.providerInputAck, OIPFrameType.providerPermissionAck,
        OIPFrameType.providerStationAttachAck, OIPFrameType.providerControlAck, OIPFrameType.providerSession,
        OIPFrameType.providerArtifact, OIPFrameType.approvalNeeded, OIPFrameType.error
    ]

    /// Feed every decoded server frame; frames that are not Provider frames are ignored.
    public func receive(_ frame: OIPServerFrame) {
        switch frame {
        case .providerInvocation(let invocation):
            apply(invocation)
        case .providerActivity(let activity):
            apply(activity)
        case .providerMessage(let message):
            apply(message)
        case .providerInterruptAck(let ack):
            apply(ack)
        case .providerInputAck(let ack):
            applyInput(ack)
        case .providerPermissionAck(let ack):
            applyPermission(ack)
        case .event(OIPFrameType.approvalNeeded, _, let body):
            if let approval = OIPProviderApproval(body) {
                apply(approval)
            }
        case .error, .providerStationAttachAck, .providerControlAck, .providerSession, .providerArtifact:
            receiveRequestAnswer(frame)
        default:
            break
        }
    }

    /// An ERROR may answer an approval, a pairing request, a Control change, a message, a profile change or a
    /// Stop; each ACK answers its own request.
    /// `provider_session` is the Station's Control state; `provider_artifact` is the preview.
    func receiveRequestAnswer(_ frame: OIPServerFrame) {
        switch frame {
        case .error(let error):
            receive(error)
        case .providerStationAttachAck(let ack):
            applyAttach(ack)
        case .providerControlAck(let ack):
            applyControl(ack)
        case .providerSession(let session):
            applySession(session)
        case .providerArtifact(let artifact):
            apply(artifact)
        default:
            break
        }
    }

    func receive(_ error: OIPServerError) {
        if error.isProviderStationOnly {
            stationRefusal = true
        }
        if let requestID = error.requestID {
            failAttach(requestID, StationPairingRules.refused)
            failControl(requestID, WorkRoomControlRules.refused)
            failInput(requestID, WorkRoomInputRules.rejectionText(reason: nil))
            failPermission(requestID, WorkRoomPermission.rejectionText(reason: nil))
            failStop(requestID)
        }
        if error.code == .string(OIPErrorCode.staleAnswer) {
            markAnsweredElsewhere(requestID: error.requestID)
        }
    }

    /// Sends one request frame and arms its timeout. `fail` runs when the timeout passes or the write fails; each
    /// `fail*` it calls is a no-op once the request is no longer in flight, so a late timer or failure changes nothing.
    func dispatch(
        _ frame: [String: JSONValue], over transport: WorkRoomTransport, timeout: Duration,
        fail: @escaping @MainActor (WorkRoomStore, WorkRoomRequest.Unanswered) -> Void
    ) {
        schedule(timeout) { [weak self] in
            self.map { fail($0, .timedOut) }
        }
        transport.send(frame) { [weak self] in
            self.map { fail($0, .notSent) }
        }
    }

    /// The CONNECTED snapshot after a reconnect: its nested Provider Invocations go through the
    /// same decoding, allow-lists and revision gate as live frames. An invocation the gate
    /// rejects (older or equal revision, or none) keeps the local one, children included, so a
    /// snapshot never takes the screen backwards. Its Control triple has its own revision gate and is applied
    /// even when the invocation itself is not newer. Anything that fails validation is dropped.
    public func receiveSnapshot(_ connected: OIPConnected) {
        hasConnected = true
        defer { attachWithRememberedCode() }
        guard connected.serverNewer else {
            return
        }
        for item in connected.chatItems ?? [] {
            guard let fields = item.objectValue,
                  fields["type"]?.stringValue == OIPFrameType.providerInvocation,
                  let invocation = OIPProviderInvocation(fields) else {
                continue
            }
            let applied = apply(invocation)
            if let owner = fields["controlOwner"]?.stringValue.flatMap(OIPControlOwner.init(rawValue:)),
               let phase = fields["controlPhase"]?.stringValue.flatMap(OIPControlPhase.init(rawValue:)),
               let revision = fields["controlRevision"]?.intValue {
                applyControl(invocation.invocationID, owner, phase, revision)
            }
            // A snapshot the gate rejected still fills in children the store has not seen, never replacing any.
            for child in fields["activities"]?.arrayValue ?? [] {
                if let activity = OIPProviderActivity(Self.liveFrame(of: child, in: fields, idKey: "activityId")),
                   applied || !(activities[activity.invocationID]?.contains { $0.activityID == activity.activityID } ?? false) {
                    apply(activity)
                }
            }
            for child in fields["messages"]?.arrayValue ?? [] {
                if let message = OIPProviderMessage(Self.liveFrame(of: child, in: fields, idKey: "messageId")),
                   applied || !messages.contains(where: {
                       $0.invocationID == message.invocationID && $0.messageID == message.messageID
                   }) {
                    apply(message)
                }
            }
            guard applied else {
                continue
            }
            if let child = fields["artifact"]?.objectValue,
               let artifact = OIPProviderArtifact(Self.liveFrame(of: .object(child), in: fields, idKey: "artifactId")) {
                apply(artifact)
            }
        }
    }

    /// The connection dropped. A Stop still waiting for its acknowledgement fails visibly as needing
    /// confirmation and is never retried. Input and Permission requests that come later fail through here too.
    public func connectionDidDrop() {
        transport = nil
        if let requestID = attachRequestID {
            failAttach(requestID, StationPairingRules.connectionDropped)
        }
        if let request = input {
            failInput(request.requestID, WorkRoomInputRules.connectionDropped)
        }
        if let request = permissionChange {
            failPermission(request.requestID, WorkRoomPermission.connectionDropped)
        }
        if let request = controlChange {
            failControl(request.requestID, WorkRoomControlRules.connectionDropped)
        }
        for (key, request) in stops where request.phase == .requesting {
            holdBarrier(key, .unconfirmed)
        }
    }

    /// A nested child as the live frame it stands for: the invocation's correlation fields added
    /// and the child's `id` under the live id key, so it is decoded by the same rules.
    static func liveFrame(
        of child: JSONValue, in invocation: [String: JSONValue], idKey: String
    ) -> [String: JSONValue] {
        var frame = child.objectValue ?? [:]
        frame[idKey] = frame["id"]
        for key in ["invocationId", "parentToolCallId", "provider"] {
            frame[key] = invocation[key]
        }
        return frame
    }

    func pendingKey(inWorkRoom workRoomID: String) -> String? {
        let members = invocations.filter { workRoomKey(of: $0) == workRoomID }
        return currentInvocation(of: members)?.invocationID
    }

    func workRoomKey(of invocation: OIPProviderInvocation) -> String {
        invocation.workroomID ?? invocation.invocationID
    }

    func apply(_ activity: OIPProviderActivity) {
        // A child event for an invocation not seen yet is dropped, not buffered.
        guard isKnown(activity.invocationID, activity.parentToolCallID, activity.provider) else {
            return
        }
        activities[activity.invocationID, default: []].upsert(activity, id: \.activityID)
    }

    func apply(_ message: OIPProviderMessage) {
        guard isKnown(message.invocationID, message.parentToolCallID, message.provider) else {
            return
        }
        if let index = messages.firstIndex(where: {
            $0.invocationID == message.invocationID && $0.messageID == message.messageID
        }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    /// A screenshot is kept only for a known invocation and only when it passed every check and carries the
    /// invocation's current revision. Any other artifact frame for that invocation removes its preview, so an
    /// outdated or invalid image never lingers and a replay cannot revive one. A frame for an invocation not
    /// seen yet is dropped, not buffered.
    func apply(_ artifact: OIPProviderArtifact) {
        guard let invocation = invocations.first(where: {
            $0.invocationID == artifact.invocationID
                && $0.parentToolCallID == artifact.parentToolCallID
                && $0.provider == artifact.provider
        }) else {
            return
        }
        if let screenshot = artifact.screenshot, screenshot.stateRevision == invocation.stateRevision {
            previews[artifact.invocationID] = screenshot
        } else {
            previews[artifact.invocationID] = nil
        }
    }

    /// The state revision gate: once an invocation has a revision, a frame without a newer one
    /// is dropped, and an equal one is a no-op. An unversioned invocation accepts any frame.
    /// Returns whether the frame was applied.
    @discardableResult
    func apply(_ incoming: OIPProviderInvocation) -> Bool {
        guard let index = invocations.firstIndex(where: { $0.invocationID == incoming.invocationID }) else {
            invocations.append(incoming)
            meetBarrier(of: incoming)
            return true
        }
        let stored = invocations[index]
        guard stored.parentToolCallID == incoming.parentToolCallID, stored.provider == incoming.provider else {
            return false
        }
        if let storedRevision = stored.stateRevision {
            guard let revision = incoming.stateRevision, revision > storedRevision else {
                return false
            }
        }
        invocations[index] = stored.merging(incoming)
        // A newer state removes a preview made for an older one.
        if previews[incoming.invocationID]?.stateRevision != invocations[index].stateRevision {
            previews[incoming.invocationID] = nil
        }
        // A newer revision or the end of the run releases a Stop; the gate above already dropped any replay.
        if let request = stops[incoming.invocationID],
           invocations[index].status?.isTerminal == true || request.revision.map({ (incoming.stateRevision ?? 0) > $0 }) == true {
            stops[incoming.invocationID] = nil
        }
        if invocations[index].status?.isTerminal == true {
            stopRejections[incoming.invocationID] = nil
            pendingApprovals[incoming.invocationID] = nil
            answeredApprovals = answeredApprovals.filter { !$0.hasPrefix("\(incoming.invocationID)\n") }
        }
        return true
    }

    func isKnown(_ invocationID: String, _ parentToolCallID: String, _ provider: OIPProvider) -> Bool {
        invocations.contains {
            $0.invocationID == invocationID && $0.parentToolCallID == parentToolCallID && $0.provider == provider
        }
    }

    /// The latest continuation, or the root when there is none.
    func currentInvocation(of members: [OIPProviderInvocation]) -> OIPProviderInvocation? {
        guard let root = members.first(where: { $0.continuationOf == nil }) ?? members.first else {
            return nil
        }
        return members.last { $0.invocationID != root.invocationID } ?? root
    }

    /// Root: the first member that continues nothing (or the first member). Current: the last
    /// continuation, or the root. The card shows the root's place and the current's state.
    func workRoom(id: String, members: [OIPProviderInvocation]) -> WorkRoom? {
        guard let root = members.first(where: { $0.continuationOf == nil }) ?? members.first else {
            return nil
        }
        let current = currentInvocation(of: members) ?? root
        let status = current.status ?? .running
        let memberIDs = Set(members.map(\.invocationID))
        let pendingApproval = approval(for: current, status: status)
        let control = control(id: id, members: members)
        var seenMessages = Set<String>()
        return WorkRoom(
            id: id,
            toolCallID: root.parentToolCallID,
            provider: root.provider,
            title: current.taskTitle ?? root.taskTitle,
            status: status,
            summary: current.summary(for: status),
            activities: members.flatMap { (activities[$0.invocationID] ?? []).sorted { $0.order < $1.order } },
            messages: messages.filter {
                memberIDs.contains($0.invocationID) && seenMessages.insert($0.messageID).inserted
            },
            approval: pendingApproval,
            stop: stop(for: current, status: status),
            composer: composer(id: id, current: current, isDeciding: pendingApproval?.isActive == true, control: control),
            permission: permission(id: id, current: current, members: members),
            control: control,
            preview: previews[current.invocationID].flatMap { $0.stateRevision == current.stateRevision ? $0 : nil }
        )
    }
}
