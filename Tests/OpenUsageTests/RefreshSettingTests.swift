import XCTest
@testable import OpenUsage

/// Covers the refresh cadence as a single source of truth: `RefreshSetting` validation, and the snapshot
/// cache TTL tracking the chosen interval (so cached data survives a relaunch within the interval and a
/// shorter interval immediately invalidates older snapshots).
@MainActor
final class RefreshSettingTests: XCTestCase {
    // MARK: - RefreshSetting validation

    func testAbsentKeyFallsBackToDefault() {
        let defaults = makeDefaults("absent")
        XCTAssertEqual(RefreshSetting.minutes(from: defaults), RefreshSetting.defaultMinutes)
        XCTAssertEqual(RefreshSetting.minutes(from: defaults), 5)
        XCTAssertEqual(RefreshSetting.interval(from: defaults), 300)
    }

    func testValidStoredValueIsReturned() {
        let defaults = makeDefaults("valid")
        for minutes in RefreshSetting.allowedMinutes {
            defaults.set(minutes, forKey: RefreshSetting.key)
            XCTAssertEqual(RefreshSetting.minutes(from: defaults), minutes)
            XCTAssertEqual(RefreshSetting.interval(from: defaults), TimeInterval(minutes * 60))
        }
    }

    func testInvalidStoredValueFallsBackToDefault() {
        let defaults = makeDefaults("invalid")
        for bogus in [0, 1, 7, 20, 60, -5] {
            defaults.set(bogus, forKey: RefreshSetting.key)
            XCTAssertEqual(RefreshSetting.minutes(from: defaults), RefreshSetting.defaultMinutes)
        }
    }

    // MARK: - Cache TTL tied to the interval

    func testCacheReusedAcrossRestartWithinChosenInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-within")
        suite.set(5, forKey: RefreshSetting.key) // 5 min interval => 300s TTL

        // A prior session left a snapshot 4 minutes ago.
        storeSnapshot(used: 20, age: 240, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0) // within interval => served from cache, no fetch
        XCTAssertNotNil(store.snapshots["test"])
    }

    func testCacheExpiresPastChosenInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-expired")
        suite.set(5, forKey: RefreshSetting.key) // 5 min interval => 300s TTL

        // A prior session left a snapshot 6 minutes ago — older than the interval.
        storeSnapshot(used: 20, age: 360, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1) // past interval => refetched
    }

    func testShorteningIntervalInvalidatesPreviouslyValidSnapshot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("shorten")
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-480) // 8 minutes old
        ))

        suite.set(10, forKey: RefreshSetting.key) // 600s TTL => 480 < 600, still fresh
        XCTAssertNotNil(cache.snapshot(providerID: "test"))

        suite.set(5, forKey: RefreshSetting.key) // 300s TTL => 480 >= 300, now expired
        XCTAssertNil(cache.snapshot(providerID: "test"))
    }

    // MARK: - Helpers

    private func storeSnapshot(used: Double, age: TimeInterval, into suite: UserDefaults, now: Date) {
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-age)
        ))
    }

    private func makeRuntime(used: Double) -> CountingProviderRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: "test",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: used, limit: 100)
        )
        return CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: "test",
                displayName: "Test",
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
                refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    /// Builds a store backed by the *dynamic* cache (TTL read live from `suite`) — the relaunch case.
    private func makeStore(runtime: CountingProviderRuntime, suite: UserDefaults, now: Date) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now }),
            defaults: suite
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.RefreshSetting.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
