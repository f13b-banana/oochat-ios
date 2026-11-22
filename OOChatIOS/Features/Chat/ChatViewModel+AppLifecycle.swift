import ConnectOnionKit
import SwiftUI
import UIKit
import UserNotifications

extension ChatViewModel {
    /// Keeps active deliveries alive while the app moves between foreground and background.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            presenceCoordinator.applicationDidBecomeInactive()
            beginBackgroundDeliveryHold()
        case .active:
            client.applicationDidBecomeActive()
            Task { await refreshHistory() }
            presenceCoordinator.applicationDidBecomeActive()
            endBackgroundDeliveryHold()
        case .inactive:
            presenceCoordinator.applicationDidBecomeInactive()
        default:
            break
        }
    }

    func beginBackgroundDeliveryHold() {
        guard backgroundDeliveryTaskID == .invalid,
              deliveryCoordinator.hasActiveDeliveries else {
            return
        }
        backgroundDeliveryTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "HostedAgentDelivery"
        ) { [weak self] in
            self?.endBackgroundDeliveryHold()
        }
    }

    func endBackgroundDeliveryHold() {
        guard backgroundDeliveryTaskID != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundDeliveryTaskID)
        backgroundDeliveryTaskID = .invalid
    }
}

extension ChatViewModel {
    /// Finished runs and waiting approvals reach the notifier; an answered approval takes its notification away.
    func observeRunsForNotifications() {
        deliveryCoordinator.onRunFinished = { [weak self] conversationID, reply, isMirrored in
            self?.runDidFinish(conversationID: conversationID, reply: reply, isMirrored: isMirrored)
        }
        interactionCoordinator.onPresented = { [weak self] interaction, conversationID in
            self?.interactionDidArrive(interaction, conversationID: conversationID)
        }
        interactionCoordinator.onDismissed = { [weak self] interaction, _ in
            if case .approval(let request) = interaction {
                self?.chatNotifier?.removeApprovalNotification(approvalID: request.id)
            }
        }
    }

    /// A run ended: notify while the app is in the background, otherwise let VoiceOver say so.
    /// A Mirrored Turn was started on another of the person's devices, which notifies for it.
    func runDidFinish(conversationID: String, reply: String, isMirrored: Bool) {
        let name = agentName(forConversationID: conversationID)
        let isActive = UIApplication.shared.applicationState == .active
        if ChatNotifier.shouldNotify(isAppActive: isActive, isMirrored: isMirrored) {
            chatNotifier?.notifyRunFinished(conversationID: conversationID, agentName: name, reply: reply)
        } else if isActive {
            AccessibilityNotification.Announcement("\(name) replied").post()
        }
    }

    private func agentName(forConversationID id: String) -> String {
        conversation(withID: id).flatMap { agent(for: $0)?.displayName } ?? "Your agent"
    }
}

extension ChatViewModel {
    /// An approval is waiting: notify while the app is in the background. One answered from a
    /// notification before its card had loaded is answered now.
    func interactionDidArrive(_ interaction: HostedAgentInteraction, conversationID: String) {
        guard case .approval(let request) = interaction else {
            return
        }
        if let queued = queuedApprovalAnswer, queued.approvalID == request.id {
            queuedApprovalAnswer = nil
            answer(queued.answer, approvalID: request.id)
            return
        }
        let isActive = UIApplication.shared.applicationState == .active
        guard ChatNotifier.shouldNotify(
            isAppActive: isActive,
            isMirrored: deliveryCoordinator.isMirroredTurn(conversationID: conversationID)
        ) else {
            return
        }
        chatNotifier?.notifyApproval(
            conversationID: conversationID,
            agentName: agentName(forConversationID: conversationID),
            request: request
        )
    }

    /// Allow once or Skip from a notification: open that chat, then answer its card. After a cold
    /// launch the card arrives once the chat reconnects, so the answer waits for it.
    func answerApproval(_ answer: ChatNotifier.ApprovalAnswer, approvalID: String, conversationID: String) {
        selectConversation(withID: conversationID)
        guard activePendingApproval?.id == approvalID else {
            queuedApprovalAnswer = (answer, approvalID)
            connectActiveConversationOnOpen()
            return
        }
        self.answer(answer, approvalID: approvalID)
    }

    private func answer(_ answer: ChatNotifier.ApprovalAnswer, approvalID: String) {
        switch answer {
        case .allowOnce:
            allowPendingApprovalOnce(id: approvalID)
        case .skip:
            skipPendingApproval(id: approvalID)
        }
    }
}

/// Notifies when a run ends or an approval waits while the app is in the background, and opens the chat when tapped.
@MainActor
final class ChatNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum ApprovalAnswer {
        case allowOnce, skip
    }

    nonisolated static let conversationKey = "conversationID"
    nonisolated static let approvalKey = "approvalID"
    nonisolated static let approvalCategory = "approval"
    nonisolated static let allowOnceAction = "allowOnce"
    nonisolated static let skipAction = "skip"

    private struct Tap {
        let action: String
        let approvalID: String?
        let conversationID: String
    }

    private let center = UNUserNotificationCenter.current()
    private var pendingTap: Tap?
    var onOpenConversation: ((String) -> Void)? {
        didSet { pendingTap.map(handle) }
    }
    /// The answer, the approval's ID and its conversation's ID.
    var onApprovalAnswer: ((ApprovalAnswer, String, String) -> Void)? {
        didSet { pendingTap.map(handle) }
    }

    override init() {
        super.init()
        center.delegate = self
        // Both open the app on that chat first, so the answer goes over a live connection.
        // Allow once also needs the phone unlocked.
        let allow = UNNotificationAction(
            identifier: Self.allowOnceAction,
            title: "Allow once",
            options: [.foreground, .authenticationRequired]
        )
        let skip = UNNotificationAction(identifier: Self.skipAction, title: "Skip", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, skip], intentIdentifiers: [])
        ])
    }

    /// "<agent> needs your approval", the one-line summary, and the Allow once / Skip buttons.
    nonisolated static func approvalContent(
        conversationID: String,
        agentName: String,
        request: ToolApprovalRequest
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(agentName) needs your approval"
        content.body = OOApprovalDisclosure.summary(tool: request.tool, arguments: request.arguments)
        content.sound = .default
        content.categoryIdentifier = approvalCategory
        content.userInfo = [conversationKey: conversationID, approvalKey: request.id]
        return content
    }

    func notifyApproval(conversationID: String, agentName: String, request: ToolApprovalRequest) {
        let content = Self.approvalContent(conversationID: conversationID, agentName: agentName, request: request)
        center.add(UNNotificationRequest(identifier: "approval-\(request.id)", content: content, trigger: nil))
    }

    /// The card was answered or went away, so its notification shouldn't linger.
    func removeApprovalNotification(approvalID: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(approvalID)"])
        center.removePendingNotificationRequests(withIdentifiers: ["approval-\(approvalID)"])
    }

    /// Notify only while the app is in the background, and only on the device that sent the
    /// turn: a linked device mirroring it stays quiet, so one turn never rings twice.
    nonisolated static func shouldNotify(isAppActive: Bool, isMirrored: Bool = false) -> Bool {
        !isAppActive && !isMirrored
    }

    /// The reply's first line, at most 100 characters; "Finished." when there's no text.
    nonisolated static func preview(of reply: String) -> String {
        let firstLine = reply
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else {
            return "Finished."
        }
        return firstLine.count > 100 ? String(firstLine.prefix(99)) + "…" : firstLine
    }

    /// Asked the first time a message is sent, not at launch. iOS only shows the prompt once.
    func requestPermissionIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyRunFinished(conversationID: String, agentName: String, reply: String) {
        let content = UNMutableNotificationContent()
        content.title = agentName
        content.body = Self.preview(of: reply)
        content.sound = .default
        content.userInfo = [Self.conversationKey: conversationID]
        center.add(UNNotificationRequest(identifier: "finished-\(conversationID)", content: content, trigger: nil))
    }

    // One posted just before the app came to the front stays in Notification Centre, unshown.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    // Tapping it opens that chat; Allow once and Skip also answer the approval.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let conversationID = info[Self.conversationKey] as? String else {
            return
        }
        let tap = Tap(
            action: response.actionIdentifier,
            approvalID: info[Self.approvalKey] as? String,
            conversationID: conversationID
        )
        await MainActor.run {
            self.handle(tap)
        }
    }

    /// A tap that launched the app can land before the app has set the callbacks, so it waits for them.
    private func handle(_ tap: Tap) {
        guard let onOpenConversation, let onApprovalAnswer else {
            pendingTap = tap
            return
        }
        pendingTap = nil
        switch (tap.action, tap.approvalID) {
        case (Self.allowOnceAction, let approvalID?):
            onApprovalAnswer(.allowOnce, approvalID, tap.conversationID)
        case (Self.skipAction, let approvalID?):
            onApprovalAnswer(.skip, approvalID, tap.conversationID)
        default:
            onOpenConversation(tap.conversationID)
        }
    }
}
