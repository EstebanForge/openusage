import Foundation

/// Bundled model-pricing manifest used to impute Cursor spend from the usage CSV.
/// Ported from `../cursorcat/Sources/CursorCat/Support/ModelManifest.swift`; the only
/// behavioral change is loading via `Bundle.module` instead of cursorcat's `AppBundle`.
struct CursorModelManifest: Decodable, Sendable {
    let retrievedAt: String
    let pricing: [String: CursorModelManifestPricingEntry]
    let aliasRules: [CursorModelManifestAliasRule]

    enum CodingKeys: String, CodingKey {
        case retrievedAt = "retrieved_at"
        case pricing
        case aliasRules = "alias_rules"
    }

    static let empty = CursorModelManifest(retrievedAt: "", pricing: [:], aliasRules: [])
}

struct CursorModelManifestPricingEntry: Decodable, Sendable {
    let displayName: String
    let provider: String
    let familyID: String
    let familyDisplayName: String
    let inputPerMillion: Double
    let cacheWritePerMillion: Double
    let cacheReadPerMillion: Double
    let outputPerMillion: Double
    let applyMaxModeUplift: Bool
    let longContextInputThreshold: Int?
    let longContextInputMultiplier: Double?
    let longContextOutputMultiplier: Double?
    let longContextCachedInputMultiplier: Double?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case provider
        case familyID = "family_id"
        case familyDisplayName = "family_display_name"
        case inputPerMillion = "input_per_million"
        case cacheWritePerMillion = "cache_write_per_million"
        case cacheReadPerMillion = "cache_read_per_million"
        case outputPerMillion = "output_per_million"
        case applyMaxModeUplift = "apply_max_mode_uplift"
        case longContextInputThreshold = "long_context_input_threshold"
        case longContextInputMultiplier = "long_context_input_multiplier"
        case longContextOutputMultiplier = "long_context_output_multiplier"
        case longContextCachedInputMultiplier = "long_context_cached_input_multiplier"
    }
}

struct CursorModelManifestAliasRule: Decodable, Sendable {
    let pattern: String
    let canonical: String
}

protocol CursorModelManifestSource: Sendable {
    func loadManifest() throws -> CursorModelManifest
}

struct CursorBundledModelManifestSource: CursorModelManifestSource {
    func loadManifest() throws -> CursorModelManifest {
        // `.copy("Resources/model_manifest.json")` lands the file at the bundle root, so look there
        // first; the "Resources" subdirectory lookup is a defensive fallback if SwiftPM nests it.
        let url = Bundle.openUsageResources.url(forResource: "model_manifest", withExtension: "json")
            ?? Bundle.openUsageResources.url(forResource: "model_manifest", withExtension: "json", subdirectory: "Resources")
        guard let url else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CursorModelManifest.self, from: data)
    }
}
