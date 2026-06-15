import Foundation

/// Shared, behavior-free parsing chores used by more than one provider. Consolidated here so a new
/// provider reuses the same JSON/number/percent handling instead of copying it.
enum ProviderParse {
    /// Decode a top-level JSON object from raw response data.
    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Permissive numeric read: accepts JSON numbers and numeric strings, rejecting non-finite values.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        }
        if let string = value as? String {
            let doubleValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return doubleValue?.isFinite == true ? doubleValue : nil
        }
        return nil
    }

    /// Clamp a percentage into 0...100, treating non-finite input as 0.
    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// Convert integer cents to dollars, preserving the providers' existing rounding behavior.
    static func centsToDollars(_ cents: Double) -> Double {
        (cents / 100 * 100).rounded() / 100
    }
}

extension String {
    /// Percent-encode for use as an `application/x-www-form-urlencoded` value.
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    /// Drop any trailing slashes, for joining base URLs and paths.
    var trimmingTrailingSlashes: String {
        var copy = self
        while copy.hasSuffix("/") {
            copy.removeLast()
        }
        return copy
    }
}
