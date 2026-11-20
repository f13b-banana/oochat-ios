import Foundation

/// Where the Stop Barrier is kept between launches. `UserDefaults` conforms as it is; tests pass a double.
public protocol WorkRoomBarrierStorage: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: WorkRoomBarrierStorage {}

/// One Stop Barrier as it is saved: the invocation, the revision the Stop was sent or acknowledged
/// against, how far it got, and when an acknowledged one stops being trusted.
struct StoredStopBarrier: Codable, Equatable {
    var invocationId: String
    var stateRevision: Int?
    var phase: String
    var expiresAt: Double?

    static let phases: Set<String> = ["requesting", "acknowledged", "unconfirmed"]
}

enum WorkRoomBarrierStore {
    static func key(scope: String) -> String {
        "workroom.stop-barrier.\(scope)"
    }

    /// The saved barriers, nil when the storage cannot be trusted: wrong type, unreadable JSON, wrong
    /// shape, an unknown phase, an empty id or the same invocation twice. Nothing saved is an empty list.
    static func load(from storage: WorkRoomBarrierStorage, key: String) -> [StoredStopBarrier]? {
        guard let stored = storage.object(forKey: key) else {
            return []
        }
        guard let data = stored as? Data,
              let entries = try? JSONDecoder().decode([StoredStopBarrier].self, from: data),
              entries.allSatisfy({ !$0.invocationId.isEmpty && StoredStopBarrier.phases.contains($0.phase) }),
              Set(entries.map(\.invocationId)).count == entries.count else {
            return nil
        }
        return entries
    }

    static func save(_ entries: [StoredStopBarrier], to storage: WorkRoomBarrierStorage, key: String) {
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries.sorted { $0.invocationId < $1.invocationId }) else {
            storage.removeObject(forKey: key)
            return
        }
        storage.set(data, forKey: key)
    }
}
