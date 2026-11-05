public enum SessionState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)   // 0 = first try, 1 or more = after a drop
    case connected
    case failed(Failure)
    public enum Failure: Equatable, Sendable { case offline, ended, incompatible }
}

public enum SessionEvent: Sendable {
    case open, close            // the user opens or closes the session
    case connectedFrame         // CONNECTED arrived
    case socketClosed           // close, timeout or transport error
    case incompatibleError      // ERROR with code -32010 only
    case notFound               // SESSION_STATUS answered not_found
}

public func reduce(
    _ state: SessionState,
    _ event: SessionEvent,
    maxAttempts: Int = ReconnectPolicy.defaultMaxAttempts
) -> SessionState {
    switch (state, event) {

    // Rule 1: Any state + close -> idle
    case (_, .close):
        return .idle

    // Rule 2: idle or failed + open -> connecting(0)
    case (.idle, .open),
         (.failed, .open):
        return .connecting(attempt: 0)

    // Rule 3: connecting + connectedFrame -> connected
    case (.connecting, .connectedFrame):
        return .connected

    // Rule 4: connected + socketClosed -> connecting(1)
    // or offline when no retry
    case (.connected, .socketClosed):
        if 1 < maxAttempts {
            return .connecting(attempt: 1)
        } else {
            return .failed(.offline)
        }

    // Rule 5: connecting(n) + socketClosed
    //         -> connecting(n + 1) while attempts left
    case (.connecting(let attempt), .socketClosed)
        where attempt + 1 < maxAttempts:
            return .connecting(attempt: attempt + 1)

    // Rule 6: connecting(n), n >= maxAttempts
    //         + socketClosed -> failed(offline)
    case (.connecting, .socketClosed):
        return .failed(.offline)

    // Rule 7: connecting or connected + incompatibleError
    //         -> failed(incompatible)
    case (.connecting, .incompatibleError),
         (.connected, .incompatibleError):
        return .failed(.incompatible)

    // Rule 8: connecting or connected + notFound
    //         -> failed(ended)
    case (.connecting, .notFound),
         (.connected, .notFound):
        return .failed(.ended)

    // Rule 9: All other combinations leave state unchanged
    default:
        return state
    }
}

extension SessionState {
    public func displayName(hasBookmark: Bool) -> String {
        switch self {

        // Idle
        case .idle:
            return "Not Connected"

        // Reconnecting
        case .connecting(let attempt)
            where attempt > 0:
                return "Reconnecting"

        // Resuming
        case .connecting:
            if hasBookmark {
                return "Resuming"
            } else {
                return "Connecting"
            }

        // Connected
        case .connected:
            return "Connected"

        // Offline
        case .failed(.offline):
            return "Offline"

        // Ended
        case .failed(.ended):
            return "Ended"

        // Incompatible
        case .failed(.incompatible):
            return "Incompatible"
        }
    }
}
