import Foundation

struct MiniMaxMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
    var plan: String?
}

/// Normalizes the MiniMax token-plan response into a single "Session" meter.
///
/// Two response shapes exist:
/// - **Count mode**: `current_interval_total_count > 0` — prompts consumed out of a plan ceiling.
/// - **Percent mode**: `total_count` is 0/absent but `remaining_percent` is present — the newer
///   Token Plan API reports a 0–100 remaining fraction.
///
/// CN endpoints report model-call counts (15× prompts); GLOBAL reports prompts directly. The display
/// divisor only touches the final `used`/`limit`, never the plan-tier inference (which works on raw
/// counts against per-region tier tables).
enum MiniMaxUsageMapper {
    static let codingPlanWindowMs = 5 * 60 * 60 * 1000           // 5 hours
    static let codingPlanToleranceMs = 10 * 60 * 1000           // 10 minutes
    static let modelCallsPerPrompt = 15

    // GLOBAL plan tiers keyed by prompt limit.
    private static let globalPlanByPromptLimit: [Int: String] = [
        100: "Starter", 300: "Plus", 1000: "Max", 2000: "Ultra"
    ]
    // CN plan tiers keyed by model-call limit (prompts × 15).
    private static let cnPlanByCallLimit: [Int: String] = [
        600: "Starter", 1500: "Plus", 4500: "Max"
    ]

    struct ParsedUsage: Equatable, Sendable {
        var planName: String?
        var used: Double
        var total: Double
        var resetsAt: Date?
        var periodDurationMs: Int?
        var isPercent: Bool
    }

    /// Parse the response body into raw usage. Throws `sessionExpired` when the API's own status code
    /// indicates an auth failure, or an arbitrary message for other API-level errors. Returns nil when
    /// no usable entry exists (the provider treats that as an unparseable error).
    static func parse(body: [String: Any], endpoint: MiniMaxEndpoint, now: Date) throws -> ParsedUsage? {
        let data = (body["data"] as? [String: Any]) ?? body

        // API-level status check (MiniMax nests its own status under base_resp).
        if let baseResp = (data["base_resp"] as? [String: Any]) ?? (body["base_resp"] as? [String: Any]) {
            // flatMap avoids a Double? here: a present-but-non-integer status_code must not satisfy
            // `code != 0` (which would wrongly throw) — it should be skipped.
            if let code = ProviderParse.number(baseResp["status_code"]).flatMap(Int.init(exactly:)), code != 0 {
                let message = ((baseResp["status_msg"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = message.lowercased()
                if code == 1004 || lower.contains("log in") || lower.contains("cookie") {
                    throw MiniMaxAuthError.sessionExpired
                }
                // Surface the API's own error text verbatim instead of masking it as a parse failure.
                throw message.isEmpty ? MiniMaxUsageError.apiStatus(code) : MiniMaxUsageError.apiMessage(message)
            }
        }

        guard let modelRemains = ((data["model_remains"] as? [Any]) ?? (body["model_remains"] as? [Any]) ?? (data["modelRemains"] as? [Any])),
              !modelRemains.isEmpty
        else {
            return nil
        }

        // Pick the best entry: prefer one with a non-zero total_count; fall back to the "general"
        // model's percent-only entry, then any percent-only entry.
        let divisor = endpoint.displayDivisor
        var chosen: [String: Any]?
        var generalPercentCandidate: [String: Any]?
        var anyPercentCandidate: [String: Any]?
        for entry in modelRemains {
            guard let item = entry as? [String: Any] else { continue }
            let total = number(item, "current_interval_total_count") ?? number(item, "currentIntervalTotalCount")
            if let total, total > 0, (total / divisor).rounded() > 0 {
                chosen = item
                break
            }
            let remainingPercent = number(item, "current_interval_remaining_percent") ?? number(item, "currentIntervalRemainingPercent")
            if let remainingPercent, (0...100).contains(remainingPercent) {
                if anyPercentCandidate == nil { anyPercentCandidate = item }
                let modelName = (item["model_name"] as? String) ?? (item["modelName"] as? String)
                if generalPercentCandidate == nil && modelName == "general" {
                    generalPercentCandidate = item
                }
            }
        }
        chosen = chosen ?? generalPercentCandidate ?? anyPercentCandidate
        guard let chosen else { return nil }

        let total = number(chosen, "current_interval_total_count") ?? number(chosen, "currentIntervalTotalCount")
        let remainingPercent = number(chosen, "current_interval_remaining_percent") ?? number(chosen, "currentIntervalRemainingPercent")

        let hasDisplayableCount = total.map { $0 > 0 && ($0 / divisor).rounded() > 0 } ?? false

        let startMs = epochToMs(number(chosen, "start_time") ?? number(chosen, "startTime"))
        let endMs = epochToMs(number(chosen, "end_time") ?? number(chosen, "endTime"))
        let remainsRaw = number(chosen, "remains_time") ?? number(chosen, "remainsTime")
        let nowMs = now.timeIntervalSince1970 * 1000
        let remainsMs: Double? = {
            guard let raw = remainsRaw else { return nil }
            return inferRemainsMs(raw, endMs: endMs, nowMs: nowMs)
        }()
        let resetsAt = resetDate(endMs: endMs, remainsMs: remainsMs, nowMs: nowMs)
        let periodDurationMs = periodDuration(startMs: startMs, endMs: endMs)
        let explicitPlanName = planName(body: body, data: data)

        // Percent mode: total is 0/absent but remaining_percent exists.
        if !hasDisplayableCount, let remainingPercent {
            let percentUsed = max(0, min(100, 100 - remainingPercent))
            return ParsedUsage(
                planName: explicitPlanName,
                used: percentUsed,
                total: 100,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                isPercent: true
            )
        }

        guard hasDisplayableCount, let total else { return nil }

        let explicitUsed = number(chosen, "current_interval_used_count") ?? number(chosen, "currentIntervalUsedCount") ?? number(chosen, "used_count") ?? number(chosen, "used")

        let remainingCount = firstPresent(chosen, keys: [
            "current_interval_remaining_count", "currentIntervalRemainingCount",
            "current_interval_remains_count", "currentIntervalRemainsCount",
            "current_interval_remain_count", "currentIntervalRemainCount",
            "remaining_count", "remainingCount", "remains_count", "remainsCount",
            "remaining", "remains", "left_count", "leftCount"
        ])
        let usageCount = number(chosen, "current_interval_usage_count") ?? number(chosen, "currentIntervalUsageCount")
        let inferredRemaining = remainingCount ?? usageCount

        var used = explicitUsed
        if used == nil, let inferredRemaining { used = total - inferredRemaining }
        guard var used else { return nil }
        used = max(0, min(used, total))

        let inferredPlan = explicitPlanName ?? inferPlanName(total: total, endpoint: endpoint)

        return ParsedUsage(
            planName: inferredPlan,
            used: used,
            total: total,
            resetsAt: resetsAt,
            periodDurationMs: periodDurationMs,
            isPercent: false
        )
    }

    /// Apply the region display divisor and build the final line + plan (with region suffix).
    static func makeUsage(parsed: ParsedUsage, endpoint: MiniMaxEndpoint) -> MiniMaxMappedUsage {
        let divisor = parsed.isPercent ? 1.0 : endpoint.displayDivisor
        let used = (parsed.used / divisor).rounded()
        let limit = (parsed.total / divisor).rounded()

        let line = MetricLine.progress(
            label: "Session",
            used: used,
            limit: limit,
            format: parsed.isPercent ? .percent : .count(suffix: "prompts"),
            resetsAt: parsed.resetsAt,
            periodDurationMs: parsed.periodDurationMs
        )

        var plan = parsed.planName
        if plan != nil {
            plan = "\(plan!) (\(endpoint == .cn ? "CN" : "GLOBAL"))"
        }
        return MiniMaxMappedUsage(lines: [line], plan: plan)
    }

    // MARK: - Helpers

    private static func number(_ item: [String: Any], _ key: String) -> Double? {
        ProviderParse.number(item[key])
    }

    private static func firstPresent(_ item: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = ProviderParse.number(item[key]) { return value }
        }
        return nil
    }

    private static func planName(body: [String: Any], data: [String: Any]) -> String? {
        for source in [data, body] {
            for key in ["current_subscribe_title", "plan_name", "plan", "current_plan_title", "combo_title"] {
                if let raw = source[key] as? String {
                    let normalized = normalizePlanName(raw)
                    if !normalized.isEmpty { return normalized }
                }
            }
        }
        return nil
    }

    private static func normalizePlanName(_ value: String) -> String {
        let compact = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let regex = try? NSRegularExpression(pattern: "^minimax\\s+coding\\s+plan\\b[:\\-]?\\s*", options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: compact.utf16.count)
            let stripped = regex.stringByReplacingMatches(in: compact, range: range, withTemplate: "")
            if !stripped.isEmpty { return stripped }
        }
        if compact.range(of: "coding plan", options: .caseInsensitive) != nil { return "Coding Plan" }
        return compact
    }

    private static func inferPlanName(total: Double, endpoint: MiniMaxEndpoint) -> String? {
        let n = Int(total.rounded())
        guard n > 0 else { return nil }

        if endpoint == .cn {
            return cnPlanByCallLimit[n]
        }
        if let plan = globalPlanByPromptLimit[n] { return plan }
        // A GLOBAL response might carry model-call counts; divide and re-check.
        if n % modelCallsPerPrompt == 0, let plan = globalPlanByPromptLimit[n / modelCallsPerPrompt] {
            return plan
        }
        return nil
    }

    private static func epochToMs(_ value: Double?) -> Double? {
        guard let value, value != 0 else { return nil }
        return abs(value) < 1e10 ? value * 1000 : value
    }

    /// Infer whether `remainsRaw` is seconds or milliseconds. When `endMs` is known, pick whichever
    /// unit aligns closest to the remaining window. Otherwise constrain against the 5h coding-plan
    /// ceiling (with tolerance) before defaulting to seconds. Returns nil for `remainsRaw <= 0` (the
    /// JS null), so a missing end_time + zero remains does not produce a spurious "now" reset.
    private static func inferRemainsMs(_ remainsRaw: Double, endMs: Double?, nowMs: Double) -> Double? {
        guard remainsRaw > 0 else { return nil }
        let asSecondsMs = remainsRaw * 1000
        let asMillisecondsMs = remainsRaw

        if let endMs, endMs > nowMs {
            let toEnd = endMs - nowMs
            return abs(asSecondsMs - toEnd) <= abs(asMillisecondsMs - toEnd) ? asSecondsMs : asMillisecondsMs
        }

        let maxExpected = Double(codingPlanWindowMs + codingPlanToleranceMs)
        let secondsValid = asSecondsMs <= maxExpected
        let millisValid = asMillisecondsMs <= maxExpected

        if secondsValid && !millisValid { return asSecondsMs }
        if millisValid && !secondsValid { return asMillisecondsMs }
        if secondsValid && millisValid { return asSecondsMs }
        return abs(asSecondsMs - maxExpected) <= abs(asMillisecondsMs - maxExpected) ? asSecondsMs : asMillisecondsMs
    }

    private static func resetDate(endMs: Double?, remainsMs: Double?, nowMs: Double) -> Date? {
        if let endMs { return Date(timeIntervalSince1970: endMs / 1000) }
        if let remainsMs { return Date(timeIntervalSince1970: (nowMs + remainsMs) / 1000) }
        return nil
    }

    private static func periodDuration(startMs: Double?, endMs: Double?) -> Int? {
        guard let startMs, let endMs, endMs > startMs else { return nil }
        return Int(endMs - startMs)
    }
}
