import ConnectOnionKit
import Foundation

extension HostedAgentConnection {
    /// ERROR is a connection failure, except while the host waits for an invite code (a wrong code is retryable)
    /// and for `provider_station_only` (a Station signal that the Work Room store reads).
    func handleError(_ frame: [String: JSONValue], generation: Int) async {
        let decoded = OIPServerFrame.decode(frame)
        await connectionStateObserver.deliver(conversationID: key.conversationID, provider: .frame(decoded))
        if frame["code"]?.stringValue == OIPErrorCode.staleAnswer {
            return
        }
        if awaitingOnboarding {
            connectionStateObserver.notify(
                conversationID: key.conversationID,
                update: .onboarding(.rejected(HostedAgentEvent.messageText(frame)))
            )
            return
        }
        if case .error(let error) = decoded, error.isProviderStationOnly, pendingPrompt == nil {
            return
        }
        failConnection(connectError(for: frame), generation: generation)
    }

    /// ONBOARD_REQUIRED keeps the socket open; ONBOARD_SUCCESS is followed by the host's own replay of CONNECT.
    func handleOnboarding(_ frame: [String: JSONValue]) {
        switch frame["type"]?.stringValue {
        case OIPFrameType.onboardRequired:
            guard case .onboardRequired(let required) = OIPServerFrame.decode(frame) else {
                return
            }
            awaitingOnboarding = true
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            let waiters = Array(connectWaiters.values)
            connectWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: onboardingPlaceholderResult())
            }
            connectionStateObserver.notify(conversationID: key.conversationID, update: .onboarding(.required(required)))
        case OIPFrameType.onboardSuccess:
            guard awaitingOnboarding else {
                return
            }
            awaitingOnboarding = false
            scheduleConnectTimeout(generation: socketGeneration)
            connectionStateObserver.notify(conversationID: key.conversationID, update: .onboarding(.granted))
        default:
            break
        }
    }

    /// Lets the app save the agent while the invite prompt is open; it carries no session.
    func onboardingPlaceholderResult() -> HostedAgentResult {
        HostedAgentResult(
            output: nil,
            endpointLabel: endpoint?.label ?? key.agentAddress,
            serverSession: serverSession,
            sessionModes: nil
        )
    }

    func submitOnboarding(code: String) async throws {
        guard awaitingOnboarding, let socket else {
            throw HostedAgentClientError.closed
        }
        try await send(try frames.onboardSubmit(inviteCode: code), over: socket)
    }
}
