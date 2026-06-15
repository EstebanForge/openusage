import Foundation

/// Single source of truth for the background refresh cadence.
///
/// The General settings picker, the periodic refresh loop, and the snapshot-cache TTL all read the
/// cadence through here so they can never disagree: the cache treats a snapshot as fresh for exactly
/// one refresh interval, and the loop re-fetches when that window elapses.
enum RefreshSetting {
    static let key = "refreshMinutes"
    static let allowedMinutes = [5, 10, 15, 30]
    static let defaultMinutes = 5

    /// The persisted choice, validated. An absent key reads back as `0`, which (like any out-of-range
    /// value) falls back to the default so callers always get a sane cadence.
    static func minutes(from defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: key)
        return allowedMinutes.contains(stored) ? stored : defaultMinutes
    }

    static func interval(from defaults: UserDefaults = .standard) -> TimeInterval {
        TimeInterval(minutes(from: defaults) * 60)
    }
}
