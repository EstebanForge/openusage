import Foundation
import Observation

@MainActor
@Observable
final class WidgetDataStore {
    private let registry: WidgetRegistry
    private let providersByID: [String: ProviderRuntime]
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// Whether a provider is currently enabled. Injected so the store consults the single
    /// `ProviderEnablementStore` without owning it; defaults to "all enabled" for tests and previews.
    private let isProviderEnabled: @MainActor (String) -> Bool
    /// The user's widget order (already enablement-filtered) that drives the menu-bar value. Injected
    /// so the store reads `LayoutStore.visiblePlaced` without owning it; defaults to registry order.
    private let orderedDescriptors: @MainActor () -> [WidgetDescriptor]

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"

    var snapshots: [String: ProviderSnapshot] = [:]
    var refreshingProviderIDs: Set<String> = []
    /// Wall-clock time the most recent full refresh pass finished. Together with the chosen refresh
    /// cadence it drives the dashboard footer's live "Next update in …" countdown, so the footer reflects
    /// the real schedule instead of a hardcoded value. `nil` until the first pass completes.
    var lastRefreshAt: Date?
    /// Latest refresh error per provider (e.g. "Not logged in. Run `codex` to authenticate."). Set when
    /// a refresh comes back as an error snapshot, cleared on the next successful one. The dashboard
    /// renders it as a warning indicator beside the provider name; the last good snapshot keeps
    /// displaying (stale-while-revalidate) instead of being replaced by dead "No data" rows.
    var providerErrors: [String: String] = [:]

    /// Global meter style: whether every bounded tile (and the menu-bar value) renders as "used" or
    /// "left/remaining". Persisted so the choice survives relaunch; defaults to `.remaining`.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// Global reset-countdown format: relative ("Resets in 4d 17h") or absolute ("Resets tomorrow at
    /// 9:00 AM"). Persisted across relaunch; defaults to `.relative`. Toggled by clicking a reset label.
    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        orderedDescriptors: (@MainActor () -> [WidgetDescriptor])? = nil
    ) {
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.cache = cache
        self.defaults = defaults
        self.isProviderEnabled = isProviderEnabled
        self.orderedDescriptors = orderedDescriptors ?? { registry.descriptors }
        self.meterStyle = defaults.string(forKey: Self.meterStyleKey)
            .flatMap(WidgetDisplayMode.init(rawValue:)) ?? .remaining
        self.resetDisplayMode = defaults.string(forKey: Self.resetDisplayModeKey)
            .flatMap(ResetDisplayMode.init(rawValue:)) ?? .relative
        // Stale-while-revalidate: load whatever was cached (expired included) so the menu bar and
        // dashboard show last-known values immediately at launch instead of "—"; the refresh loop
        // replaces them as soon as fresh data lands.
        self.snapshots = cache.loadSnapshots(providerIDs: registry.providers.map(\.id))
    }

    /// Refresh every enabled provider, concurrently — one slow provider never delays the rest.
    /// Everything stays MainActor-isolated; the overlap happens at the network awaits inside each
    /// provider, and the per-provider in-flight guard in `refresh` still prevents duplicate fetches.
    /// `force` bypasses the snapshot cache (the manual "refresh now" path); the periodic loop keeps
    /// honoring it.
    func refreshAll(force: Bool = false) async {
        // `Task {}` from MainActor context inherits the isolation (a task-group child can't capture
        // the non-Sendable store), so: fire one task per provider, then await them all.
        let tasks = registry.providers.map(\.id)
            .filter { isProviderEnabled($0) }
            .map { providerID in
                Task { await self.refresh(providerID: providerID, force: force) }
            }
        for task in tasks {
            await task.value
        }
        // Stamp the end of the pass so the footer countdown targets the next scheduled refresh
        // (this time + one refresh interval), mirroring the periodic loop that sleeps one interval
        // after each pass.
        lastRefreshAt = Date()
    }

    func refresh(providerID: String, force: Bool = false) async {
        guard isProviderEnabled(providerID) else { return }
        if !force, let cached = cache.snapshot(providerID: providerID) {
            // Skip the no-op write: `@Observable` doesn't compare values, so unconditionally
            // re-assigning an unchanged snapshot would re-render the menu-bar label every pass.
            if snapshots[providerID] != cached {
                snapshots[providerID] = cached
            }
            return
        }

        guard let provider = providersByID[providerID] else { return }
        // Skip if an in-flight refresh already owns this provider (e.g. the background timer racing the
        // first popover open), so we never fire duplicate network calls for the same provider.
        guard !refreshingProviderIDs.contains(providerID) else { return }
        refreshingProviderIDs.insert(providerID)
        let snapshot = await provider.refresh()
        if let message = Self.errorMessage(in: snapshot) {
            // Failed refresh: surface the error but keep the last good snapshot on screen rather than
            // collapsing every row to "No data".
            providerErrors[providerID] = message
        } else {
            if providerErrors[providerID] != nil {
                providerErrors[providerID] = nil
            }
            snapshots[providerID] = snapshot
            cache.store(snapshot)
        }
        refreshingProviderIDs.remove(providerID)
    }

    /// The provider's latest refresh error, or `nil` when its last refresh succeeded.
    func errorMessage(for providerID: String) -> String? {
        providerErrors[providerID]
    }

    /// A snapshot that carries only error lines is a failed refresh; its message comes from the badge.
    private static func errorMessage(in snapshot: ProviderSnapshot) -> String? {
        guard !snapshot.lines.isEmpty, snapshot.lines.allSatisfy(\.isError) else { return nil }
        if case .badge(_, let text, _, _) = snapshot.lines[0] { return text }
        return "Refresh failed"
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        if PlanWidget.isPlan(descriptor) {
            var result = descriptor.sample
            if let plan = plan(for: descriptor.providerID) {
                result.valueTextOverride = plan
                result.hasData = true
            } else {
                result.hasData = false
            }
            return result
        }

        var result: WidgetData
        if let snapshot = snapshots[descriptor.providerID],
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
        } else {
            // No real metric line backs this placed tile, so the sample's numbers are placeholders.
            // Flag it as no-data; the tile renders "No data" instead of inventing usage.
            result = descriptor.sample
            result.hasData = false
        }

        // Single global choke point: tiles, the Add-Widget gallery, and the menu-bar value all funnel
        // through here, so stamping the mode once makes them follow the global setting. Inert for
        // unbounded tiles (limit == nil), whose displayed value ignores displayMode.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        return result
    }

    /// The plan label for a provider's latest snapshot (also feeds the optional Plan widget). `nil` until a
    /// snapshot exists or when the provider doesn't expose a plan.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    var menuBarPrimaryText: String {
        // The tray mirrors the user's widget order: the first placed, enabled tile that has real data
        // drives it, skipping any no-data tile so it never shows a missing metric's placeholder. When
        // nothing has real data yet, it shows the no-data marker ("—") beside the tray icon — never a
        // fabricated amount.
        let primary = orderedDescriptors()
            .filter { isProviderEnabled($0.providerID) }
            .lazy
            .map { self.data(for: $0) }
            .first { $0.hasData }

        guard let primary else { return WidgetData.noDataHeadline }
        return primary.valueText
    }

    private func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _):
            return WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: used,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
        case .text(_, let value, _, _):
            return resolveText(value, descriptor: descriptor)
        case .badge(_, let text, _, let subtitle):
            var data = descriptor.sample
            data.valueTextOverride = text
            data.subtitleOverride = subtitle
            return data
        }
    }

    private func resolveText(_ value: String, descriptor: WidgetDescriptor) -> WidgetData? {
        switch descriptor.sample.kind {
        case .dollars:
            guard let amount = Self.firstCurrencyAmount(in: value) else { return descriptor.sample }
            return WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: .dollars,
                used: amount,
                limit: descriptor.sample.limit,
                countSuffix: descriptor.sample.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                // A raw-text descriptor shows the provider's line verbatim (the parsed amount above
                // still feeds the menu bar's compact value).
                valueTextOverride: descriptor.sample.preservesRawText ? value : nil,
                subtitleOverride: descriptor.sample.subtitleOverride,
                unboundedValueWord: descriptor.sample.unboundedValueWord,
                infoNote: descriptor.sample.infoNote
            )
        case .count:
            guard let count = Self.firstNumber(in: value) else { return descriptor.sample }
            return WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: .count,
                used: count,
                limit: descriptor.sample.limit,
                countSuffix: descriptor.sample.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                subtitleOverride: descriptor.sample.subtitleOverride,
                unboundedValueWord: descriptor.sample.unboundedValueWord,
                infoNote: descriptor.sample.infoNote
            )
        case .percent:
            guard let percent = Self.firstNumber(in: value) else { return descriptor.sample }
            return WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: .percent,
                used: percent,
                limit: descriptor.sample.limit ?? 100,
                countSuffix: descriptor.sample.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                subtitleOverride: descriptor.sample.subtitleOverride,
                infoNote: descriptor.sample.infoNote
            )
        }
    }

    static func firstCurrencyAmount(in value: String) -> Double? {
        let pattern = #"[-+]?\$([0-9][0-9,]*(?:\.[0-9]+)?)"#
        guard let match = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = value[match].replacingOccurrences(of: "$", with: "")
        return Double(matched.replacingOccurrences(of: ",", with: ""))
    }

    static func firstNumber(in value: String) -> Double? {
        let pattern = #"[-+]?[0-9][0-9,]*(?:\.[0-9]+)?"#
        guard let match = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(value[match].replacingOccurrences(of: ",", with: ""))
    }
}

