import Foundation

/// provider_artifact: a real screenshot of the Provider's workspace, inline. A frame that names a Provider
/// Invocation always decodes, so the store can remove the preview a bad frame replaces; `screenshot` is nil
/// when any check failed. A frame without that correlation stays `.unknown`.
public struct OIPProviderArtifact: Equatable, Sendable {
    public let invocationID: String
    public let parentToolCallID: String
    public let provider: OIPProvider
    public let screenshot: Screenshot?

    /// A screenshot that passed every check except the invocation's current revision, which the store applies.
    public struct Screenshot: Equatable, Sendable {
        public let artifactID: String
        /// Positive, and the revision of the invocation it is evidence for.
        public let stateRevision: Int
        /// Decoded PNG or JPEG bytes whose header matches the declared type.
        public let imageData: Data
        /// One of Core's two approved descriptions; the accessibility label.
        public let alt: String
    }

    /// Core's limit on the whole data URL, in characters.
    static let dataURLLimit = 262_144
    private static let artifactIDLimit = 128
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let jpegStart: [UInt8] = [0xFF, 0xD8]
    private static let jpegEnd: [UInt8] = [0xFF, 0xD9]
    private static let idAlphabet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._:-".utf8)
    private static let base64Alphabet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/".utf8)

    init?(_ frame: [String: JSONValue]) {
        guard let invocationID = frame["invocationId"]?.stringValue, !invocationID.isEmpty, invocationID.count <= 512,
              let parentToolCallID = frame["parentToolCallId"]?.stringValue, !parentToolCallID.isEmpty,
              parentToolCallID.count <= 512,
              let provider = frame["provider"]?.stringValue.flatMap(OIPProvider.init(rawValue:)) else {
            return nil
        }
        self.invocationID = invocationID
        self.parentToolCallID = parentToolCallID
        self.provider = provider
        screenshot = Self.screenshot(frame)
    }

    private static func screenshot(_ frame: [String: JSONValue]) -> Screenshot? {
        guard let artifactID = frame["artifactId"]?.stringValue, isArtifactID(artifactID),
              frame["kind"]?.stringValue == "screenshot",
              let revision = frame["stateRevision"]?.intValue, revision > 0,
              let alt = frame["alt"]?.stringValue, ProviderCopy.artifactAlts.contains(alt),
              let url = frame["thumbnailDataUrl"]?.stringValue,
              let data = imageData(url) else {
            return nil
        }
        return Screenshot(artifactID: artifactID, stateRevision: revision, imageData: data, alt: alt)
    }

    /// `^[A-Za-z0-9._:-]{1,128}$`
    private static func isArtifactID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= artifactIDLimit && id.utf8.allSatisfy(idAlphabet.contains)
    }

    /// `^data:image/(png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$`, at most 262,144 characters, whose bytes start
    /// with the PNG signature or are a JPEG (start and end markers), matching the declared type.
    private static func imageData(_ url: String) -> Data? {
        guard url.utf8.count <= dataURLLimit else {
            return nil
        }
        let isPNG = url.hasPrefix("data:image/png;base64,")
        guard isPNG || url.hasPrefix("data:image/jpeg;base64,") else {
            return nil
        }
        let payload = url.drop { $0 != "," }.dropFirst()
        let body = payload.utf8.reversed().drop { $0 == 0x3D }
        guard payload.utf8.count - body.count <= 2, payload.utf8.count % 4 == 0, !body.isEmpty,
              body.allSatisfy(base64Alphabet.contains), let data = Data(base64Encoded: String(payload)) else {
            return nil
        }
        let bytes = [UInt8](data)
        if isPNG {
            return bytes.starts(with: pngSignature) ? data : nil
        }
        return bytes.starts(with: jpegStart) && bytes.suffix(2).elementsEqual(jpegEnd) ? data : nil
    }
}
