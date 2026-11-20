import Foundation

/// Dashboard leaves the app to show the page or a notice if its too big

public enum OIPDashboard: Equatable, Sendable {
    case page(html: String)
    case tooLarge(bytes: Int)

    /// host's websocket transport limit.
    /// if the frame is over 1 MiB, the chat drops
    public static let socketMessageBytes = 256 * 1024 * 1024

    /// Pages above this are not rendered
    public static let clientCapBytes = 16 * 1024 * 1024

    public init(html: String) {
        let bytes = html.utf8.count
        self = bytes > Self.clientCapBytes ? .tooLarge(bytes: bytes) : .page(html: html)
    }
}
