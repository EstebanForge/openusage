import Foundation

struct CodexMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum CodexUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
    /// Codex flex credits are worth 4¢ each; the credits line leads with the dollar value
    /// (mirrors the JS plugin's `CREDIT_USD_RATE`).
    static let creditUSDRate = 0.04

    static func mapUsageResponse(_ response: HTTPResponse, now: Date = Date()) throws -> CodexMappedUsage {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw CodexAuthError.tokenExpired
            }
            throw CodexUsageError.requestFailed(statusCode: response.statusCode)
        }

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw CodexUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        let rateLimit = body["rate_limit"] as? [String: Any]
        let primaryWindow = rateLimit?["primary_window"] as? [String: Any]
        let secondaryWindow = rateLimit?["secondary_window"] as? [String: Any]

        if let headerPrimary = ProviderParse.number(response.header("x-codex-primary-used-percent")) {
            lines.append(progress(
                label: "Session",
                used: headerPrimary,
                resetWindow: primaryWindow,
                now: now,
                periodDurationMs: sessionPeriodMs
            ))
        }
        if let headerSecondary = ProviderParse.number(response.header("x-codex-secondary-used-percent")) {
            lines.append(progress(
                label: "Weekly",
                used: headerSecondary,
                resetWindow: secondaryWindow,
                now: now,
                periodDurationMs: weeklyPeriodMs
            ))
        }

        if !lines.contains(where: { $0.label == "Session" }),
           let used = ProviderParse.number(primaryWindow?["used_percent"]) {
            lines.append(progress(
                label: "Session",
                used: used,
                resetWindow: primaryWindow,
                now: now,
                periodDurationMs: sessionPeriodMs
            ))
        }
        if !lines.contains(where: { $0.label == "Weekly" }),
           let used = ProviderParse.number(secondaryWindow?["used_percent"]) {
            lines.append(progress(
                label: "Weekly",
                used: used,
                resetWindow: secondaryWindow,
                now: now,
                periodDurationMs: weeklyPeriodMs
            ))
        }

        appendAdditionalRateLimits(from: body, to: &lines, now: now)
        appendReviewLimit(from: body, to: &lines, now: now)

        if let remaining = readCreditsRemaining(response: response, body: body) {
            lines.append(.text(label: "Credits", value: creditsLabel(remaining: remaining)))
        }

        if lines.isEmpty {
            lines.append(.badge(label: "Status", text: "No usage data", colorHex: "#A3A3A3"))
        }

        return CodexMappedUsage(plan: formatCodexPlan(body["plan_type"]), lines: lines)
    }

    static func appendTokenUsage(_ usage: CcusageDailyUsage, to lines: inout [MetricLine], now: Date = Date()) {
        let today = dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey(from:))

        let todayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == today }
        let yesterdayEntry = usage.daily.first { dayKey(fromUsageDate: $0.date) == yesterday }

        lines.append(dayUsageLine(label: "Today", entry: todayEntry, includeZeroTokens: true))
        lines.append(dayUsageLine(label: "Yesterday", entry: yesterdayEntry, includeZeroTokens: true))

        let totalTokens = usage.daily.reduce(0) { $0 + $1.totalTokens }
        let costValues = usage.daily.compactMap(\.costUSD)
        let totalCost = costValues.isEmpty ? nil : costValues.reduce(0, +)
        if totalTokens > 0 {
            lines.append(.text(
                label: "Last 30 Days",
                value: costAndTokensLabel(tokens: totalTokens, costUSD: totalCost)
            ))
        }
    }

    private static func appendAdditionalRateLimits(from body: [String: Any], to lines: inout [MetricLine], now: Date) {
        guard let entries = body["additional_rate_limits"] as? [[String: Any]] else { return }
        for entry in entries {
            guard let rateLimit = entry["rate_limit"] as? [String: Any] else { continue }
            let rawName = (entry["limit_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shortName = rawName.replacingOccurrences(
                of: #"^GPT-[\d.]+-Codex-"#,
                with: "",
                options: .regularExpression
            )
            let label = shortName.isEmpty ? (rawName.isEmpty ? "Model" : rawName) : shortName

            if let primary = rateLimit["primary_window"] as? [String: Any],
               let used = ProviderParse.number(primary["used_percent"]) {
                lines.append(progress(
                    label: label,
                    used: used,
                    resetWindow: primary,
                    now: now,
                    periodDurationMs: readPeriodMs(primary) ?? sessionPeriodMs
                ))
            }
            if let secondary = rateLimit["secondary_window"] as? [String: Any],
               let used = ProviderParse.number(secondary["used_percent"]) {
                lines.append(progress(
                    label: "\(label) Weekly",
                    used: used,
                    resetWindow: secondary,
                    now: now,
                    periodDurationMs: readPeriodMs(secondary) ?? weeklyPeriodMs
                ))
            }
        }
    }

    private static func appendReviewLimit(from body: [String: Any], to lines: inout [MetricLine], now: Date) {
        guard let review = body["code_review_rate_limit"] as? [String: Any],
              let window = review["primary_window"] as? [String: Any],
              let used = ProviderParse.number(window["used_percent"])
        else {
            return
        }
        lines.append(progress(
            label: "Reviews",
            used: used,
            resetWindow: window,
            now: now,
            periodDurationMs: weeklyPeriodMs
        ))
    }

    private static func progress(
        label: String,
        used: Double,
        resetWindow: [String: Any]?,
        now: Date,
        periodDurationMs: Int
    ) -> MetricLine {
        .progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(resetWindow, now: now),
            periodDurationMs: periodDurationMs
        )
    }

    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        guard let window else { return nil }
        if let resetAt = ProviderParse.number(window["reset_at"]) {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = ProviderParse.number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func readPeriodMs(_ window: [String: Any]) -> Int? {
        guard let seconds = ProviderParse.number(window["limit_window_seconds"]) else { return nil }
        return Int(seconds * 1000)
    }

    /// "$32.84 · 821 credits" — dollar value first (remaining × 4¢), then the raw credit count.
    /// Mirrors the JS plugin's refactored credits display; negative balances clamp to zero.
    static func creditsLabel(remaining: Double) -> String {
        let credits = max(0, Int(remaining.rounded(.down)))
        let usd = Double(credits) * creditUSDRate
        return String(format: "$%.2f", usd) + " · \(credits.formatted(.number.locale(Locale(identifier: "en_US")))) credits"
    }

    private static func readCreditsRemaining(response: HTTPResponse, body: [String: Any]) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = ProviderParse.number(credits["balance"]) {
                return balance
            }
            if credits["has_credits"] as? Bool == false {
                return 0
            }
        }
        return ProviderParse.number(response.header("x-codex-credits-balance"))
    }

    static func formatCodexPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite":
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        default:
            return raw
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func dayKey(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func dayKey(fromUsageDate rawDate: String) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let match = value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(value[match])
        }
        if value.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
            let year = value.prefix(4)
            let month = value.dropFirst(4).prefix(2)
            let day = value.suffix(2)
            return "\(year)-\(month)-\(day)"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy"
        if let date = formatter.date(from: value) {
            return dayKey(from: date)
        }

        if let date = OpenUsageISO8601.date(from: value) {
            return dayKey(from: date)
        }
        return nil
    }

    static func dayUsageLine(label: String, entry: CcusageDay?, includeZeroTokens: Bool) -> MetricLine {
        let tokens = entry?.totalTokens ?? 0
        let cost = entry?.costUSD
        if tokens > 0 || includeZeroTokens {
            return .text(label: label, value: costAndTokensLabel(tokens: tokens, costUSD: cost))
        }
        return .text(label: label, value: "")
    }

    static func costAndTokensLabel(tokens: Int, costUSD: Double?) -> String {
        var parts: [String] = []
        if let costUSD {
            parts.append(String(format: "$%.2f", costUSD))
        }
        parts.append("\(formatTokens(tokens)) tokens")
        return parts.joined(separator: " · ")
    }

    static func formatTokens(_ tokens: Int) -> String {
        let absValue = abs(tokens)
        let sign = tokens < 0 ? "-" : ""
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1_000, 1_000, "K")
        ]
        for unit in units where Double(absValue) >= unit.threshold {
            let scaled = Double(absValue) / unit.divisor
            let formatted = scaled >= 10
                ? String(Int(scaled.rounded()))
                : String(format: "%.1f", scaled).replacingOccurrences(of: ".0", with: "")
            return sign + formatted + unit.suffix
        }
        return "\(tokens)"
    }

}

enum CodexUsageError: Error, LocalizedError, Equatable {
    case requestFailed(statusCode: Int)
    case invalidResponse
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode):
            return "Usage request failed (HTTP \(statusCode)). Try again later."
        case .invalidResponse:
            return "Usage response invalid. Try again later."
        case .connectionFailed:
            return "Usage request failed. Check your connection."
        }
    }
}

