import Foundation

/// Metrics enabled on first launch — one or two sensible ones per provider so every provider
/// section shows real rows out of the box. `LayoutStore` filters this to whatever the active
/// registry actually knows, so registries that don't define an ID (e.g. the test fixtures)
/// silently ignore it. The provider-section order isn't seeded here: an empty saved order
/// reconciles to plain registry order in `LayoutStore`.
enum DefaultLayout {
    static let metricIDs: [String] = [
        "claude.session", "claude.weekly",
        "codex.session", "codex.weekly",
        "devin.weekly", "devin.daily",
        "grok.creditsUsed",
        "cursor.usage"
    ]
}
