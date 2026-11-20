import ConnectOnionKit
import Foundation

/// What the invite prompt of one conversation shows.
struct OnboardingPrompt: Equatable {
    var methods: [String]
    var message: String?
    var isSubmitting = false

    var acceptsInviteCode: Bool {
        methods.contains("invite_code")
    }
}

extension ChatViewModel {
    var activeOnboarding: OnboardingPrompt? {
        activeConversationID.flatMap { onboardingByConversationID[$0] }
    }

    func applyOnboarding(_ onboarding: HostedAgentOnboarding, forConversationID conversationID: String) {
        switch onboarding {
        case .required(let required):
            var prompt = onboardingByConversationID[conversationID] ?? OnboardingPrompt(methods: required.methods)
            prompt.methods = required.methods
            prompt.isSubmitting = false
            onboardingByConversationID[conversationID] = prompt
        case .rejected(let message):
            guard var prompt = onboardingByConversationID[conversationID] else {
                return
            }
            prompt.message = message
            prompt.isSubmitting = false
            onboardingByConversationID[conversationID] = prompt
            onboardingCodesByConversationID[conversationID] = nil
        case .granted:
            onboardingByConversationID[conversationID] = nil
        }
    }

    /// Sends the code as ONBOARD_SUBMIT on the open connection. The host replays CONNECT itself afterwards.
    /// For a Station the same code is the pairing code, so the Work Room store attaches with it automatically.
    func submitInviteCode(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let conversationID = activeConversationID, let agent = activeAgent,
              var prompt = onboardingByConversationID[conversationID], !prompt.isSubmitting else {
            return
        }
        prompt.isSubmitting = true
        prompt.message = nil
        onboardingByConversationID[conversationID] = prompt
        onboardingCodesByConversationID[conversationID] = code
        if isStation(agent) {
            attachRememberedOnboardingCodes(address: agent.address, isStation: true)
        }
        Task { [self] in
            do {
                try await client.submitOnboarding(agentAddress: agent.address, conversationID: conversationID, code: code)
            } catch {
                // The socket is gone (idle too long or the network dropped): the next connect asks again.
                self.onboardingByConversationID[conversationID] = nil
                self.onboardingCodesByConversationID[conversationID] = nil
                self.errorMessage = error.localizedDescription
                self.connectActiveConversationOnOpen()
            }
        }
    }

    /// Hands a typed invite code to the Work Room store once the agent is known to be a Station.
    func attachRememberedOnboardingCodes(address: String, isStation: Bool) {
        guard isStation else {
            return
        }
        for (conversationID, code) in onboardingCodesByConversationID
        where conversationState.conversation(withID: conversationID)?.agentAddress.lowercased() == address.lowercased() {
            conversationState.workRoomStore(for: conversationID).rememberOnboardingCode(code)
            onboardingCodesByConversationID[conversationID] = nil
        }
    }
}
