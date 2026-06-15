import XCTest
@testable import OpenUsage

/// Covers the "No data" state: a placed tile whose provider snapshot has no line matching the
/// descriptor's metric label must report `hasData == false`, render the exact "—"/"No data" copy,
/// and never leak its placeholder sample numbers into the menu bar.
@MainActor
final class WidgetNoDataTests: XCTestCase {
    func testDataForFlagsMissingLineAsNoData() async {
        let (store, present, missing) = await makeRefreshedStore(suite: "missing-line")

        XCTAssertTrue(store.data(for: present).hasData)
        XCTAssertFalse(store.data(for: missing).hasData)
    }

    func testNoDataHeadlineAndSubtitleCopy() async {
        let (store, present, missing) = await makeRefreshedStore(suite: "copy")

        let blank = store.data(for: missing)
        XCTAssertFalse(blank.hasData)
        XCTAssertEqual(blank.headline, "—")
        XCTAssertEqual(blank.subtitle, "No data")

        let real = store.data(for: present)
        XCTAssertTrue(real.hasData)
        XCTAssertNotEqual(real.headline, "—")
        XCTAssertNotEqual(real.subtitle, "No data")
    }

    func testValueTextHidesPlaceholderWhenNoData() async {
        // The Add-Widget gallery prints `valueText`; a missing line must never leak the descriptor's
        // placeholder sample numbers there, so `valueText` reports the no-data marker just like the tile.
        let (store, present, missing) = await makeRefreshedStore(suite: "valuetext")

        XCTAssertEqual(store.data(for: missing).valueText, WidgetData.noDataHeadline)
        XCTAssertNotEqual(store.data(for: present).valueText, WidgetData.noDataHeadline)
    }

    func testMenuBarFollowsLayoutOrder() async {
        // Both tiles have real data; the menu bar shows whichever is FIRST in the injected order,
        // proving the value is order-driven (not registry/alphabetical).
        let provider = Self.testProvider
        let alpha = boundedPercent(provider, id: "test.alpha", metric: "Alpha", sampleUsed: 11)
        let beta = boundedPercent(provider, id: "test.beta", metric: "Beta", sampleUsed: 22)
        let store = makeOrderedStore(
            provider: provider,
            descriptors: [alpha, beta],
            order: [beta, alpha],
            lines: [
                .progress(label: "Alpha", used: 40, limit: 100, format: .percent),
                .progress(label: "Beta", used: 70, limit: 100, format: .percent)
            ],
            suite: "menubar-order"
        )
        store.meterStyle = .used
        await store.refreshAll()

        XCTAssertEqual(store.menuBarPrimaryText, "70%")
    }

    func testMenuBarSkipsNoDataAndUsesNextOrderedTile() async {
        // Alpha is first in order but has no backing line; the menu bar skips it for the next ordered
        // tile (Beta) that has real data, never showing Alpha's placeholder sample.
        let provider = Self.testProvider
        let alpha = boundedPercent(provider, id: "test.alpha", metric: "Alpha", sampleUsed: 11)
        let beta = boundedPercent(provider, id: "test.beta", metric: "Beta", sampleUsed: 22)
        let store = makeOrderedStore(
            provider: provider,
            descriptors: [alpha, beta],
            order: [alpha, beta],
            lines: [.progress(label: "Beta", used: 70, limit: 100, format: .percent)],
            suite: "menubar-skip"
        )
        store.meterStyle = .used
        await store.refreshAll()

        XCTAssertEqual(store.menuBarPrimaryText, "70%")
    }

    func testMenuBarFallsBackWhenEveryOrderedTileIsNoData() async {
        // The provider refreshed, but its snapshot lacks both ordered metrics, so every tile is
        // no-data and the menu bar shows the no-data marker instead of a fabricated amount.
        let provider = Self.testProvider
        let alpha = boundedPercent(provider, id: "test.alpha", metric: "Alpha", sampleUsed: 11)
        let beta = boundedPercent(provider, id: "test.beta", metric: "Beta", sampleUsed: 22)
        let store = makeOrderedStore(
            provider: provider,
            descriptors: [alpha, beta],
            order: [alpha, beta],
            lines: [.progress(label: "Gamma", used: 10, limit: 100, format: .percent)],
            suite: "menubar-fallback"
        )
        await store.refreshAll()

        XCTAssertEqual(store.menuBarPrimaryText, WidgetData.noDataHeadline)
    }

    // MARK: - Helpers

    private func makeRefreshedStore(
        suite: String
    ) async -> (WidgetDataStore, WidgetDescriptor, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))
        let present = boundedPercent(provider, id: "test.present", metric: "Present", sampleUsed: 40)
        // Deliberately fake sample numbers we must never show once the account lacks this metric.
        let missing = boundedPercent(provider, id: "test.missing", metric: "Missing", sampleUsed: 99)
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [present, missing],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Present", used: 40, limit: 100, format: .percent)]
            )
        )
        let defaults = makeUserDefaults(suite)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [present, missing]),
            providers: [runtime],
            cache: makeCache(defaults),
            defaults: defaults
        )
        await store.refreshAll()
        return (store, present, missing)
    }

    private static let testProvider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))

    /// Builds a store whose menu-bar order is the injected `order` list, mirroring how `AppContainer`
    /// feeds `LayoutStore.visiblePlaced` into the store.
    private func makeOrderedStore(
        provider: Provider,
        descriptors: [WidgetDescriptor],
        order: [WidgetDescriptor],
        lines: [MetricLine],
        suite: String
    ) -> WidgetDataStore {
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: lines
            )
        )
        let defaults = makeUserDefaults(suite)
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            providers: [runtime],
            cache: makeCache(defaults),
            defaults: defaults,
            orderedDescriptors: { order }
        )
    }

    private func boundedPercent(
        _ provider: Provider,
        id: String,
        metric: String,
        sampleUsed: Double
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metric,
            sample: WidgetData(
                title: metric,
                icon: provider.icon,
                kind: .percent,
                used: sampleUsed,
                limit: 100
            )
        )
    }

    private func makeCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.NoData.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
