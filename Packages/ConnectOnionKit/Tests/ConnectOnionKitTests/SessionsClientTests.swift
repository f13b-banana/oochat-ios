import Foundation
import Testing
@testable import ConnectOnionKit

private final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Stub.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let (status, body) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct SessionsClientTests {
    private func client() throws -> SessionsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return SessionsClient(
            baseURL: try #require(URL(string: "http://host.test")),
            agentAddress: "0xagent",
            keyStore: InMemoryPrivateKeyStore(rawKey: Data((0..<32).map { UInt8($0) })),
            urlSession: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            requestID: { "rid" }
        )
    }

    @Test func listIsSignedAndDecoded() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        Stub.handler = { seen = $0; return (200, #"{"sessions":[{"session_id":"s1","status":"done","prompt":"hi"}]}"#) }
        let sessions = try await client().listSessions()
        #expect(sessions.map(\.sessionID) == ["s1"])
        #expect(seen?.url?.path == "/sessions")
        #expect(seen?.value(forHTTPHeaderField: "x-co-request-id") == "rid")
        #expect(seen?.value(forHTTPHeaderField: "x-co-signature")?.count == 128)
    }

    @Test func singleSessionIsSigned() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        Stub.handler = { seen = $0; return (200, #"{"session_id":"s1","status":"done","prompt":"hi"}"#) }
        _ = try await client().session(id: "s1")
        #expect(seen?.url?.path == "/sessions/s1")
        #expect(seen?.value(forHTTPHeaderField: "x-co-from") != nil)
    }

    @Test(arguments: [401, 403]) func authRejectionThrowsNotEmpty(status: Int) async {
        Stub.handler = { _ in (status, "{}") }
        await #expect(throws: SessionsClientError.authRejected(status: status)) { try await client().listSessions() }
    }

    @Test func serverErrorThrows() async {
        Stub.handler = { _ in (500, "") }
        await #expect(throws: SessionsClientError.http(status: 500)) { try await client().listSessions() }
    }

    // Hosts send seconds or milliseconds; zero, negative and missing mean no time.
    @Test(arguments: [
        ("1700000000", 1_700_000_000), ("1700000000500", 1_700_000_000.5),
        ("0", nil), ("-5", nil), ("null", nil)
    ] as [(String, Double?)])
    func hostTimesReadAsSecondsOrMilliseconds(raw: String, seconds: Double?) throws {
        let json = #"{"session_id":"s1","status":"done","prompt":"hi","created":\#(raw),"session":{"messages":[],"updated":\#(raw)}}"#
        let session = try JSONDecoder().decode(ConnectOnionHostedSession.self, from: Data(json.utf8))
        let expected = seconds.map(Date.init(timeIntervalSince1970:))
        #expect(session.createdDate == expected)
        #expect(session.conversation?.updatedDate == expected)
    }
}
