import Foundation

/// How the menu-bar item renders the pinned metrics: a `text` strip (provider icon + values, up to
/// three providers side by side) or the compact `bars` glyph (up to four percentage bars). Chosen in
/// Settings and persisted by `LayoutStore`; defaults to `.text`.
enum MenuBarStyle: String, Hashable, Sendable, CaseIterable {
    case text
    case bars

    var label: String {
        switch self {
        case .text: return "Text"
        case .bars: return "Bars"
        }
    }
}
