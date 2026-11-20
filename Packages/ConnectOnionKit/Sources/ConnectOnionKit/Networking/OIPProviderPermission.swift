import Foundation

/// The Permission Profile catalog a host sends with a Provider Invocation: the Provider's own options and
/// which one is active. It is all or nothing. A catalog with one invalid option, an active option that is
/// missing or not selectable, or a revision other than the enclosing frame's is dropped whole.
public struct OIPProviderPermission: Equatable, Sendable {
    public enum Reviewer: String, Equatable, Sendable {
        case user, auto, provider
    }

    public enum Risk: String, Equatable, Sendable {
        case standard, elevated
    }

    /// One Permission Profile as the host names it. `label` and `description` are shown as supplied.
    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String
        public let nativeProfileID: String
        public let reviewer: Reviewer
        public let label: String
        public let description: String
        public let risk: Risk
        /// False when the host's Outer Mode ceiling is below this option.
        public let isSelectable: Bool
        /// Why the option is not selectable; always present when `isSelectable` is false.
        public let disabledReason: String?
    }

    public let provider: OIPProvider
    public let activeOptionID: String
    /// The state revision this catalog describes; equal to the enclosing frame's `stateRevision`.
    public let effectiveRevision: Int
    public let options: [Option]

    static let optionLimit = 12
}

extension OIPProviderPermission {
    /// Nil unless the catalog is valid for this Provider and `stateRevision`, the revision of the frame that
    /// carries it.
    init?(_ value: JSONValue?, provider: OIPProvider, stateRevision: Int?) {
        guard let fields = value?.objectValue,
              fields["provider"]?.stringValue == provider.rawValue,
              fields["appliesTo"]?.stringValue == "subsequent_turn",
              let revision = fields["effectiveRevision"]?.intValue, revision > 0, revision == stateRevision,
              let activeID = safeID(fields["activeOptionId"]),
              let rawOptions = fields["options"]?.arrayValue,
              (1...Self.optionLimit).contains(rawOptions.count) else {
            return nil
        }
        let options = rawOptions.compactMap(Option.init)
        guard options.count == rawOptions.count,
              Set(options.map(\.id)).count == options.count,
              options.contains(where: { $0.id == activeID && $0.isSelectable }) else {
            return nil
        }
        self.provider = provider
        activeOptionID = activeID
        effectiveRevision = revision
        self.options = options
    }
}

extension OIPProviderPermission.Option {
    init?(_ value: JSONValue) {
        guard let fields = value.objectValue,
              let id = safeID(fields["id"]),
              let nativeID = safeID(fields["nativeProfileId"]),
              let reviewer = fields["reviewer"]?.stringValue.flatMap(OIPProviderPermission.Reviewer.init(rawValue:)),
              let label = Self.text(fields["label"], limit: 64),
              let description = Self.text(fields["description"], limit: 200),
              let risk = fields["risk"]?.stringValue.flatMap(OIPProviderPermission.Risk.init(rawValue:)),
              let selectable = fields["selectable"]?.boolValue else {
            return nil
        }
        let reason = Self.text(fields["disabledReason"], limit: 160)
        guard selectable || reason != nil else {
            return nil
        }
        self.id = id
        nativeProfileID = nativeID
        self.reviewer = reviewer
        self.label = label
        self.description = description
        self.risk = risk
        isSelectable = selectable
        disabledReason = reason
    }

    /// Non-empty, within `limit` Unicode scalars, and free of control characters.
    private static func text(_ value: JSONValue?, limit: Int) -> String? {
        guard let text = value?.stringValue, (1...limit).contains(text.unicodeScalars.count),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return text
    }
}
