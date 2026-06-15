import Foundation

/// One parsed row from Cursor's CSV usage export. `imputedCostDollars` is the locally priced dollar
/// amount (server CSV tokens × bundled model pricing); unknown models price to 0. Ported from
/// `../cursorcat/Sources/CursorCat/API/UsageCSV.swift`, dropping the actual-cost / CostMode path for v1.
struct CursorUsageCSVRow: Sendable, Equatable {
    var date: Date
    var model: String
    var maxMode: Bool
    var tokens: CursorTokenUsage
    var imputedCostDollars: Double
}

enum CursorUsageCSV {
    /// Pure parser: maps Cursor's exported CSV text into priced rows. Rows with an unparseable date or
    /// header are skipped.
    static func parse(csv: String) -> [CursorUsageCSVRow] {
        let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        var rows: [CursorUsageCSVRow] = []
        CursorCSVParser.forEachRecord(in: csv) { r in
            guard let dateStr = r["Date"]?.trimmingCharacters(in: .whitespaces),
                  !dateStr.isEmpty,
                  let date = parseDate(dateStr, iso: iso, isoFractional: isoFractional)
            else { return }

            let model = (r["Model"] ?? "").trimmingCharacters(in: .whitespaces)
            let maxMode = (r["Max Mode"] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "yes"
            let tokens = CursorTokenUsage(
                inputCacheWrite: parseIntValue(r["Input (w/ Cache Write)"] ?? ""),
                inputNoCacheWrite: parseIntValue(r["Input (w/o Cache Write)"] ?? ""),
                cacheRead: parseIntValue(r["Cache Read"] ?? ""),
                output: parseIntValue(r["Output Tokens"] ?? "")
            )
            let imputed = CursorPricing.estimatedCostDollars(model: model, maxMode: maxMode, tokens: tokens)

            rows.append(CursorUsageCSVRow(
                date: date,
                model: model,
                maxMode: maxMode,
                tokens: tokens,
                imputedCostDollars: imputed
            ))
        }
        return rows
    }

    private static func parseDate(
        _ raw: String,
        iso: ISO8601DateFormatter,
        isoFractional: ISO8601DateFormatter
    ) -> Date? {
        if let d = isoFractional.date(from: raw) { return d }
        if let d = iso.date(from: raw) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: raw)
    }

    private static func parseIntValue(_ raw: String) -> Int {
        let normalized = raw.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }
        return Int(normalized) ?? 0
    }
}
