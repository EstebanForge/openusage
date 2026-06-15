import Foundation

/// One AI provider OpenUsage can track. A conformer reads credentials already on the machine, calls the
/// provider's API, and normalizes the result into a `ProviderSnapshot` of `MetricLine` values that the UI
/// renders. See `docs/adding-a-provider.md` for the full walkthrough.
///
/// `refresh()` returns the latest snapshot. Build its `lines` from the app's small metric vocabulary,
/// choosing the case by the shape of the value:
/// - `.progress` — a bounded meter with a `used`/`limit` and a `format` (percent, dollars, or count). Use
///   for anything with a ceiling: session/weekly quotas, credits with a cap. Add `resetsAt` when the
///   window resets at a known time.
/// - `.text` — an unbounded value rendered as-is (e.g. "$12.34 spent"). Use when there is no limit to
///   show a meter against.
/// - `.badge` — a short status pill (e.g. "Disabled", or a pay-as-you-go cap). Use for state, not a number
///   to fill a bar with.
///
/// On failure, return `ProviderSnapshot.error(provider:message:)` so the error surfaces loudly in the UI
/// rather than showing stale or empty data.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> ProviderSnapshot
}

