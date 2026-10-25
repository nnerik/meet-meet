import Foundation

/// Versioned records belong to the state layer, not to a particular storage API.
@MainActor
public protocol LocalStateStoring {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}
