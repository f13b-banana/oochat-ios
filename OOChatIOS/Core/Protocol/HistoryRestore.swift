import ConnectOnionKit
import Foundation

/// Per-agent outcome of the last History Restore.
enum RestoreState: Equatable {
    case restored
    /// The agent could not be reached (or is relay-only). Retried the next time it connects.
    case pending
    /// The host answered but refused or returned something unusable. Never shown as empty history.
    case failed
}

protocol SessionsFetching: AnyObject {
    func sessions(agentAddress: String) async throws -> [ConnectOnionHostedSession]
}

/// The agent has no HTTP host we can reach (relay-only, or discovery failed).
enum HistoryRestoreError: Error { case unreachable }

enum HistoryRestore {
    /// Maps host sessions to local conversations by `session_id` (== `Conversation.id`).
    /// Unknown sessions become new conversations; a known conversation with no messages is
    /// filled in; any other known conversation only takes the host's latest `updated`, so repeat
    /// refreshes never duplicate and a later delete records the newest value seen.
    /// A Tombstone is skipped unless the host's `updated` is greater than the one it recorded;
    /// then it is restored in full, like an unknown session. A session with no visible messages
    /// creates and revives nothing; it only records its `updated` on a row that already exists.
    static func merge(
        _ sessions: [ConnectOnionHostedSession],
        agent: SavedAgent,
        into existing: [Conversation]
    ) -> [Conversation] {
        var changed: [Conversation] = []
        for session in sessions {
            // Host times rather than the restore time, so a Tombstone records the host's clock.
            let hostCreated = session.createdDate
            let created = hostCreated ?? Date()
            let messages = visibleMessages(of: session, startingAt: created)
            let updated = session.conversation?.updatedDate
            // nil when the host sent neither `updated` nor `created`: then nothing stored changes.
            let hostUpdated = session.updatedOrCreatedDate
            let local = existing.first { $0.id == session.sessionID }
            if let local, !local.isTombstone {
                if let refreshed = refreshed(local, messages: messages, hostUpdated: hostUpdated) {
                    changed.append(refreshed)
                }
                continue
            }
            if let recorded = local?.tombstoneUpdated {
                guard let updated, updated > recorded else { continue }
                // Nothing to show: the Tombstone stays one and only records the newer `updated`.
                if var tombstone = local, messages.isEmpty {
                    tombstone.tombstoneUpdated = updated
                    tombstone.hostUpdated = updated
                    changed.append(tombstone)
                    continue
                }
            }
            guard !messages.isEmpty else { continue }
            changed.append(Conversation(
                id: session.sessionID,
                title: title(for: messages),
                agentID: agent.id,
                agentAddress: agent.address,
                mode: .safe,
                createdAt: created,
                updatedAt: updated ?? created,
                messages: messages,
                serverSession: nil,
                // A Tombstone from a previous identity stays one, so the caller's filter drops it.
                identityAddress: local?.identityAddress,
                hostUpdated: hostUpdated
            ))
        }
        return changed
    }

    /// The session's user and assistant messages, a millisecond apart so they keep the transcript order when sorted by time.
    private static func visibleMessages(of session: ConnectOnionHostedSession, startingAt created: Date) -> [ChatMessage] {
        let transcript = (session.conversation?.messages ?? []).compactMap { message -> (role: ChatRole, text: String)? in
            guard message.isInternal != true, let text = message.text, let role = message.turnRole else { return nil }
            return (role == .user ? .user : .agent, text)
        }
        return transcript.enumerated().map { index, entry in
            ChatMessage(role: entry.role, content: entry.text, createdAt: created.addingTimeInterval(Double(index) / 1000))
        }
    }

    /// A known, live conversation with an empty chat filled in and a newer host time taken, or nil if neither applies.
    private static func refreshed(_ local: Conversation, messages: [ChatMessage], hostUpdated: Date?) -> Conversation? {
        var local = local
        let fillsEmptyChat = local.messages.isEmpty && !messages.isEmpty
        // Only ever forward: a stale `updated` must not lower the time a Tombstone is later recorded at.
        let newerHostTime = hostUpdated.map { hostTime in local.hostUpdated.map { hostTime > $0 } ?? true } ?? false
        guard fillsEmptyChat || newerHostTime else { return nil }
        if fillsEmptyChat { local.messages = messages }
        if newerHostTime { local.hostUpdated = hostUpdated }
        return local
    }

    static func state(for error: Error) -> RestoreState {
        // Transport failures (offline, timeout) are retryable; anything the host answered is not.
        error is HistoryRestoreError || error is URLError ? .pending : .failed
    }

    /// Named like the Mac names a restored chat: the first user message that can name it (Kit ChatTitle),
    /// never a /command. Otherwise untitled, so the next message sent here names it.
    private static func title(for messages: [ChatMessage]) -> String {
        messages.lazy
            .filter { $0.role == .user }
            .compactMap { ChatTitle.from($0.content) }
            .first ?? Conversation.defaultTitle
    }
}

extension HostedAgentClient: SessionsFetching {
    /// Sessions need the agent's HTTP host. A relay-only agent has none we can reach, so it
    /// reports unreachable (pending) rather than an empty history.
    func sessions(agentAddress: String) async throws -> [ConnectOnionHostedSession] {
        guard Self.isHostedAgentAddress(agentAddress),
              let found = try? await discovery.discover(agentAddress: agentAddress),
              found.endpoint.kind == .direct,
              var parts = URLComponents(url: found.endpoint.wsURL, resolvingAgainstBaseURL: false) else {
            throw HistoryRestoreError.unreachable
        }
        parts.scheme = parts.scheme == "wss" ? "https" : "http"
        parts.path = ""
        guard let base = parts.url else { throw HistoryRestoreError.unreachable }
        return try await SessionsClient(
            baseURL: base,
            agentAddress: agentAddress,
            keyStore: identityStore,
            urlSession: urlSession
        ).listSessions()
    }
}
