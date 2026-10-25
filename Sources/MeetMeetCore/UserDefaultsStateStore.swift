import Foundation

@MainActor
public final class UserDefaultsStateStore: LocalStateStoring {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
