import Foundation
import Observation

/// The single source of truth for which providers the user has turned off.
///
/// Only the *disabled* IDs are persisted, never the enabled ones. That keeps "everything on" as an
/// empty set, so a provider shipped in a future release defaults to enabled without any migration.
@MainActor
@Observable
final class ProviderEnablementStore {
    private static let storageKey = "openusage.disabledProviders.v1"

    private(set) var disabledIDs: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.disabledIDs = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    func setEnabled(_ enabled: Bool, for id: String) {
        if enabled {
            disabledIDs.remove(id)
        } else {
            disabledIDs.insert(id)
        }
        defaults.set(Array(disabledIDs), forKey: Self.storageKey)
    }
}
