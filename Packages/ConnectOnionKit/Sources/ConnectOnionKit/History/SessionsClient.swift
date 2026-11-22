import Foundation

/// The `session` object nested inside a hosted history record.
public struct ConnectOnionHostedConversation: Decodable, Sendable {
    public var messages: [ConnectOnionHostedMessage] = []
    public var updated: Double?

    public var updatedDate: Date? { UnixTime.date(updated) }
}

/// A Unix time from the host, which may send seconds or milliseconds.
public enum UnixTime {
    /// Values past 10^10 are milliseconds. Zero, negative or missing is no time.
    public static func date(_ timestamp: Double?) -> Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
    }
}

/// One hosted transcript entry; `text` unwraps only plain string content.
public struct ConnectOnionHostedMessage: Decodable, Sendable {
    public var role: String
    /// Tool-call records can omit `content`.
    public var content: JSONValue?
    public var isInternal: Bool?

    public var text: String? {
        guard case .string(let value)? = content else { return nil }
        return value
    }

    /// Nil for tool, system and other roles a transcript does not show.
    public var turnRole: TurnRole? { TurnRole(hostRole: role) }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case isInternal = "internal"
    }
}

/// A durable session returned by the host's `/sessions` endpoints.
public struct ConnectOnionHostedSession: Decodable, Sendable {
    public var sessionID: String
    public var status: String
    public var prompt: String
    public var result: String?
    public var conversation: ConnectOnionHostedConversation?
    public var created: Double?

    public var createdDate: Date? { UnixTime.date(created) }

    /// The host's last activity on the session: its `updated`, or `created` when it never sent one.
    public var updatedOrCreatedDate: Date? { conversation?.updatedDate ?? createdDate }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status, prompt, result
        case conversation = "session"
        case created
    }
}

public enum SessionsClientError: Error, Equatable {
    /// 401/403: the host refused our signature. Never treat as empty history.
    case authRejected(status: Int)
    /// Any other non-2xx answer.
    case http(status: Int)
    case invalidResponse
}

/// Signed `GET /sessions` and `GET /sessions/{id}` against one agent's host.
public struct SessionsClient: Sendable {
    private let baseURL: URL
    private let agentAddress: String
    private let keyStore: any PrivateKeyStoring
    private let urlSession: URLSession
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        baseURL: URL,
        agentAddress: String,
        keyStore: any PrivateKeyStoring,
        urlSession: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.baseURL = baseURL
        self.agentAddress = agentAddress
        self.keyStore = keyStore
        self.urlSession = urlSession
        self.now = now
        self.requestID = requestID
    }

    /// The caller's own sessions.
    public func listSessions() async throws -> [ConnectOnionHostedSession] {
        struct Envelope: Decodable { var sessions: [ConnectOnionHostedSession] }
        return try await get("/sessions", as: Envelope.self).sessions
    }

    public func session(id: String) async throws -> ConnectOnionHostedSession {
        // Raw: appendingPathComponent percent-encodes it once, and the host verifies the decoded path,
        // which is what url.path signs.
        try await get("/sessions/\(id)", as: ConnectOnionHostedSession.self)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        let headers = try SignedRequestHeaders.make(
            method: "GET",
            path: request.url?.path ?? path,
            to: agentAddress,
            key: keyStore.loadOrCreatePrivateKey(),
            now: now(),
            requestID: requestID()
        )
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SessionsClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw SessionsClientError.authRejected(status: http.statusCode)
        default: throw SessionsClientError.http(status: http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw SessionsClientError.invalidResponse }
    }
}
