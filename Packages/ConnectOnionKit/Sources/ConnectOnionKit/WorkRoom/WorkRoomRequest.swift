import Foundation

/// What every Work Room request (pairing, Control, message, profile change, Stop) shares: one in flight at a
/// time, a timeout, and plain copy for the ways it can end without the host doing it.
enum WorkRoomRequest {
    /// How a request in flight ended without an answer.
    enum Unanswered {
        case timedOut
        /// The transport could not write the frame.
        case notSent
    }

    static let notSent = "The request could not be sent. Check the connection and try again."

    /// Plain copy for a refusal: the request's own reasons first, then the ones every request shares, else
    /// `fallback`. The host's reason is an open string, so an unknown one gets `fallback`.
    static func rejectionText(_ reason: String?, _ own: [String: String], fallback: String) -> String {
        reason.flatMap { own[$0] ?? shared[$0] } ?? fallback
    }

    private static let shared = [
        "invalid_request": "The host could not read the request. Try again.",
        "invalid_revision": "This screen was out of date. Try again.",
        "state_unconfirmed": "The host could not confirm the state of this run. Try again."
    ]
}
