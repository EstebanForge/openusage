import XCTest
@testable import OpenUsage

/// Covers the persistence contract of `ProviderEnablementStore`: only *disabled* IDs are stored, so an
/// empty suite means everything is on and the choice survives relaunch.
@MainActor
final class ProviderEnablementStoreTests: XCTestCase {
    func testEmptySuiteEnablesEverything() {
        let store = ProviderEnablementStore(defaults: makeDefaults("empty"))

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("a-provider-that-ships-next-year"))
    }

    func testDisablingPersistsAcrossInstances() {
        let defaults = makeDefaults("persist")
        let store = ProviderEnablementStore(defaults: defaults)

        store.setEnabled(false, for: "codex")

        XCTAssertFalse(store.isEnabled("codex"))
        XCTAssertTrue(store.isEnabled("claude"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.disabledIDs, ["codex"])
        XCTAssertFalse(reloaded.isEnabled("codex"))
        XCTAssertTrue(reloaded.isEnabled("claude"))
    }

    func testReEnablingClearsDisabledStateAndPersists() {
        let defaults = makeDefaults("re-enable")
        let store = ProviderEnablementStore(defaults: defaults)

        store.setEnabled(false, for: "grok")
        store.setEnabled(true, for: "grok")

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("grok"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertTrue(reloaded.disabledIDs.isEmpty)
        XCTAssertTrue(reloaded.isEnabled("grok"))
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Enablement.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
