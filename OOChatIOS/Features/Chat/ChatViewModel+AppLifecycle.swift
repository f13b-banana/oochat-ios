import SwiftUI
import UIKit

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
