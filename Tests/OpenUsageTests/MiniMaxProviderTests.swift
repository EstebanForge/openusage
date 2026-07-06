import XCTest
@testable import OpenUsage

@MainActor
final class MiniMaxAuthStoreTests: XCTestCase {
    func testEndpointOrderGlobalFirstWhenNoCnKey() {
        let store = MiniMaxAuthStore(environment: FakeEnvironment(["MINIMAX_API_KEY": "k"]))
        XCTAssertEqual(store.endpointOrder(), [.global, .cn])
    }

    func testEndpointOrderCnFirstWhenCnKeyPresent() {
        let store = MiniMaxAuthStore(environment: FakeEnvironment([
            "MINIMAX_CN_API_KEY": "cn", "MINIMAX_API_KEY": "global"
        ]))
        XCTAssertEqual(store.endpointOrder(), [.cn, .global])
    }

    func testLoadsGlobalKey() throws {
        let store = MiniMaxAuthStore(environment: FakeEnvironment(["MINIMAX_API_KEY": "k"]))
        XCTAssertEqual(store.loadApiKey(endpoint: .global), "k")
    }

    func testLoadsCnKey() throws {
        let store = MiniMaxAuthStore(environment: FakeEnvironment(["MINIMAX_CN_API_KEY": "cn-k"]))
        XCTAssertEqual(store.loadApiKey(endpoint: .cn), "cn-k")
    }

    func testReturnsNilWhenNoKey() {
        let store = MiniMaxAuthStore(environment: FakeEnvironment([:]))
        XCTAssertNil(store.loadApiKey(endpoint: .global))
    }
}

final class MiniMaxUsageMapperTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-06-25T12:00:00.000Z")!

    func testCountModeGlobalPrompts() throws {
        let body: [String: Any] = [
            "data": ["model_remains": [[
                "current_interval_total_count": 1000,
                "current_interval_used_count": 250
            ]]]
        ]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)
        XCTAssertEqual(parsed?.used, 250)
        XCTAssertEqual(parsed?.total, 1000)
        XCTAssertEqual(parsed?.isPercent, false)
    }

    func testCountModeInfersPlanFromGlobalLimit() throws {
        let body: [String: Any] = [
            "data": ["model_remains": [[
                "current_interval_total_count": 1000,
                "current_interval_used_count": 100
            ]]]
        ]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)
        XCTAssertEqual(parsed?.planName, "Max")
    }

    func testCountModeCnDividesByFifteenForDisplay() throws {
        let body: [String: Any] = [
            "data": ["model_remains": [[
                "current_interval_total_count": 1500,
                "current_interval_used_count": 600
            ]]]
        ]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .cn, now: now)!
        let mapped = MiniMaxUsageMapper.makeUsage(parsed: parsed, endpoint: .cn)
        let line = progress(mapped.lines, "Session")!
        // 600 model-calls / 15 = 40 used; 1500 / 15 = 100 limit
        XCTAssertEqual(line.used, 40)
        XCTAssertEqual(line.limit, 100)
        XCTAssertEqual(mapped.plan, "Plus (CN)")
    }

    func testPercentModeWhenTotalIsZero() throws {
        let body: [String: Any] = [
            "data": ["model_remains": [[
                "current_interval_total_count": 0,
                "current_interval_remaining_percent": 70,
                "model_name": "general"
            ]]]
        ]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)
        XCTAssertEqual(parsed?.used, 30)
        XCTAssertEqual(parsed?.total, 100)
        XCTAssertEqual(parsed?.isPercent, true)
    }

    func testCountModeInfersRemainingFromUsageField() throws {
        // Coding Plan / remains commonly returns remaining prompts in current_interval_usage_count
        // when remaining_count is absent: used = total - usage_count.
        let body: [String: Any] = [
            "data": ["model_remains": [[
                "current_interval_total_count": 300,
                "current_interval_usage_count": 120
            ]]]
        ]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)
        // 300 total - 120 remaining = 180 used
        XCTAssertEqual(parsed?.used, 180)
    }

    func testThrowsApiMessageOnNonAuthStatus() throws {
        // M1 regression: a non-zero, non-auth base_resp must surface the API's own message verbatim,
        // not mask it as an unparseable response.
        let body: [String: Any] = [
            "data": ["base_resp": ["status_code": 2010, "status_msg": "rate limited"]]
        ]
        XCTAssertThrowsError(try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)) { error in
            XCTAssertEqual(error as? MiniMaxUsageError, .apiMessage("rate limited"))
        }
    }

    func testThrowsApiStatusWhenMessageAbsent() throws {
        let body: [String: Any] = [
            "data": ["base_resp": ["status_code": 2010]]
        ]
        XCTAssertThrowsError(try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)) { error in
            XCTAssertEqual(error as? MiniMaxUsageError, .apiStatus(2010))
        }
    }

    func testThrowsSessionExpiredOnApiAuthStatus() {
        let body: [String: Any] = [
            "data": ["base_resp": ["status_code": 1004, "status_msg": "please log in"]]
        ]
        XCTAssertThrowsError(try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)) { error in
            XCTAssertEqual(error as? MiniMaxAuthError, .sessionExpired)
        }
    }

    func testReturnsNilWhenNoModelRemains() throws {
        let body: [String: Any] = ["data": ["model_remains": []]]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)
        XCTAssertNil(parsed)
    }

    func testResetsAtFromEndTime() throws {
        // end_time as epoch seconds -> 2026-06-25T17:00:00Z
        let endSeconds = OpenUsageISO8601.date(from: "2026-06-25T17:00:00.000Z")!.timeIntervalSince1970
        let body: [String: Any] = [
            "data": ["model_remains": [[
                "current_interval_total_count": 100,
                "current_interval_used_count": 10,
                "start_time": endSeconds - 18000,
                "end_time": endSeconds
            ]]]
        ]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)!
        XCTAssertEqual(parsed.resetsAt, OpenUsageISO8601.date(from: "2026-06-25T17:00:00.000Z"))
        XCTAssertEqual(parsed.periodDurationMs, 5 * 60 * 60 * 1000)
    }

    func testNormalizePlanNameStripsPrefix() throws {
        let body: [String: Any] = [
            "data": [
                "model_remains": [["current_interval_total_count": 100, "current_interval_used_count": 10]],
                "plan_name": "MiniMax Coding Plan: Plus"
            ]
        ]
        let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: .global, now: now)
        XCTAssertEqual(parsed?.planName, "Plus")
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, _, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, periodDurationMs)
    }
}
