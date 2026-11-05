/// Deduplicates incoming server events to provide replay safety.
/// Callers pass a dedupe key from type, id, status and seq
/// as a tool_call and tool_result share one id
public struct EventLedger: Sendable {
    private var seenEventIDs: Set<String>

    public init(previouslySeen: Set<String> = []) {
        self.seenEventIDs = previouslySeen
    }

    /// Records an event ID to prevent replays
    /// - Returns: `true` if the event is new, `false` if it is a replay.
    public mutating func record(eventID: String) -> Bool {
        seenEventIDs.insert(eventID).inserted
    }
}
