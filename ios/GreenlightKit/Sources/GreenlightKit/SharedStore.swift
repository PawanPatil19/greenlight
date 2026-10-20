import Foundation

/// Settings and the last snapshot, shared between the app and the widget through an App Group.
public struct SharedStore {
    /// Must match the App Group in both targets' entitlements (see ios/project.yml).
    public static let appGroup = "group.dev.greenlight.app"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = UserDefaults(suiteName: SharedStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    private enum Key {
        static let config = "relayConfig"
        static let snapshot = "lastSnapshot"
        static let fetchedAt = "lastFetchedAt"
    }

    public var config: RelayConfig? {
        get { defaults.data(forKey: Key.config).flatMap { try? JSONDecoder().decode(RelayConfig.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.config)
            } else {
                defaults.removeObject(forKey: Key.config)
                defaults.removeObject(forKey: Key.snapshot)
            }
        }
    }

    public var client: RelayClient? { config.map { RelayClient(config: $0) } }

    /// The last snapshot the app or widget fetched, so the widget can show something offline.
    public var lastSnapshot: (snapshot: Snapshot, fetchedAt: Date)? {
        guard let data = defaults.data(forKey: Key.snapshot),
              let snapshot = try? GreenlightJSON.decoder().decode(Snapshot.self, from: data)
        else { return nil }
        let fetchedAt = defaults.object(forKey: Key.fetchedAt) as? Date ?? snapshot.serverTime
        return (snapshot, fetchedAt)
    }

    public func save(_ snapshot: Snapshot, fetchedAt: Date = Date()) {
        guard let data = try? GreenlightJSON.encoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Key.snapshot)
        defaults.set(fetchedAt, forKey: Key.fetchedAt)
    }
}
