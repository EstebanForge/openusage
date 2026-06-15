import Foundation

extension Bundle {
    /// The bundle carrying OpenUsage's copied resources (provider SVGs, Cursor model manifest).
    ///
    /// SwiftPM generates `Bundle.module` for an executable target that only looks two places: next to
    /// `Bundle.main.bundleURL` (which, for a packaged `.app`, is the app root) and a path into the build
    /// tree baked in at compile time. Neither resolves in a shipped `.app`, where the resource bundle
    /// lives in `Contents/Resources` — so `Bundle.module` hits its `fatalError` and the app crashes on
    /// launch. (A locally built app appears to work only because the baked-in build path still exists on
    /// the build machine.)
    ///
    /// This accessor looks where the resource bundle actually ships first, and only falls back to
    /// `Bundle.module` for `swift run` / `swift test`, where the build path is valid.
    static let openUsageResources: Bundle = {
        let bundleName = "OpenUsage_OpenUsage.bundle"
        let searchBases: [URL?] = [
            Bundle.main.resourceURL,                          // packaged .app: Contents/Resources
            Bundle.main.bundleURL,                            // bundle beside the app root
            Bundle(for: ResourceBundleToken.self).resourceURL,
            Bundle(for: ResourceBundleToken.self).bundleURL
        ]
        for case let base? in searchBases {
            if let bundle = Bundle(url: base.appendingPathComponent(bundleName)) {
                return bundle
            }
        }
        return .module
    }()
}

private final class ResourceBundleToken {}
