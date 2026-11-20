import Foundation

/// Defines the bounds and backoff math for reconnect attempts.
///
public struct ReconnectPolicy: Sendable {
    /// The hard limit for consecutive reconnection attempts.
    public static let defaultMaxAttempts: Int = 4

    /// Attempts allowed in one run
    public let maxAttempts: Int
    /// Delay before the first retry, doubled for subsequent retries
    public let baseDelay: TimeInterval
    /// Upper bound for a wait
    public let maxDelay: TimeInterval

    public init(
        maxAttempts: Int = ReconnectPolicy.defaultMaxAttempts,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 16
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Calculates the backoff delay for a given attempt index.
    /// - Parameter attempt: The current retry attempt (1-indexed).
    /// - Returns: The wait time in seconds before the next connection attempt.
    public func delay(for attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // exponential backoff: 1, 2, 4, 8 seconds
        let backoff = baseDelay * pow(2.0, Double(attempt - 1))
        return min(backoff, maxDelay)
    }
}
