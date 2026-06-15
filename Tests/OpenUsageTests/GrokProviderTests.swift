import XCTest
@testable import OpenUsage

final class GrokAuthStoreTests: XCTestCase {
    func testReadsTokenExpiryFromJWT() {
        let store = GrokAuthStore(now: { OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")! })
        let token = makeJWT(exp: 1_770_000_000)

        let expiry = store.tokenExpiresAt(token)

        XCTAssertEqual(expiry?.timeIntervalSince1970, 1_770_000_000)
    }

    func testLoadsAuthCandidatesFromGrokAuthFile() throws {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh"}}"#
        ])
        let store = GrokAuthStore(files: files)

        let candidates = try store.loadAuthCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.token, "token")
        XCTAssertEqual(candidates.first?.entryKey, "https://auth.x.ai::client")
    }
}

final class GrokUsageMapperTests: XCTestCase {
    func testMapsCreditsUsedAndPayAsYouGo() throws {
        let mapped = try GrokUsageMapper.mapBillingResponse(HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: billingBody(used: "2500", monthlyLimit: "10000", onDemandCap: "2500")
        ))

        XCTAssertEqual(progress(mapped.lines, "Credits used")?.used, 25)
        XCTAssertEqual(progress(mapped.lines, "Credits used")?.limit, 100)
        XCTAssertEqual(progress(mapped.lines, "Credits used")?.resetsAt, OpenUsageISO8601.date(from: "2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.text, "2500 cap")
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.colorHex, "#22c55e")
    }

    func testMapsDisabledPayAsYouGo() throws {
        let mapped = try GrokUsageMapper.mapBillingResponse(HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: billingBody(used: 4277, monthlyLimit: 60000, onDemandCap: 0)
        ))

        XCTAssertEqual(progress(mapped.lines, "Credits used")?.used ?? 0, 7.128, accuracy: 0.001)
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertEqual(badge(mapped.lines, "Pay as you go")?.colorHex, "#a3a3a3")
    }
}

@MainActor
final class GrokProviderTests: XCTestCase {
    func testRefreshesExpiredTokenPersistsAuthAndFetchesUsage() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "expired-token",
                "refresh_token": "refresh-token",
                "oidc_client_id": "client-id",
                "expires_at": "2026-01-01T00:00:00.000Z",
                "custom_field": "keep-me"
              }
            }
            """
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(String(data: request.body ?? Data(), encoding: .utf8), "grant_type=refresh_token&client_id=client-id&refresh_token=refresh-token")
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.billingURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
            }
            if request.url == GrokUsageClient.settingsURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        XCTAssertEqual(progress(snapshot.lines, "Credits used")?.used, 25)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")

        let saved = GrokAuthStore.parseAuth(files.files[GrokAuthStore.authPath] ?? "")
        let entry = saved?["https://auth.x.ai::client"]
        XCTAssertEqual(entry?.key, "new-token")
        XCTAssertEqual(entry?.refreshToken, "new-refresh")
        XCTAssertEqual(entry?.expiresAt, "2026-02-02T01:00:00.000Z")
        let savedObject = GrokAuthStore.parseJSONObject(files.files[GrokAuthStore.authPath] ?? "")
        let rawEntry = savedObject?["https://auth.x.ai::client"] as? [String: Any]
        XCTAssertEqual(rawEntry?["custom_field"] as? String, "keep-me")
    }

    func testRetriesBillingOnceAfterAuthError() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "old-token",
                "refresh_token": "refresh-token",
                "expires_at": "2026-06-01T00:00:00.000Z"
              }
            }
            """
        ])
        var billingCalls = 0
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.billingURL {
                billingCalls += 1
                if billingCalls == 1 {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: billingBody(used: 2500, monthlyLimit: 10000, onDemandCap: 0))
            }
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.settingsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        let billingAuths = httpClient.requests
            .filter { $0.url == GrokUsageClient.billingURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(billingAuths, ["Bearer old-token", "Bearer new-token"])
    }
}

@MainActor
final class GrokWidgetDataStoreTests: XCTestCase {
    func testResolvesBadgeSnapshotIntoWidgetText() async {
        let provider = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let descriptor = WidgetDescriptor(
            id: "grok.payAsYouGo",
            providerID: provider.id,
            metricLabel: "Pay as you go",
            sample: WidgetData(title: "Pay as you go", icon: provider.icon, kind: .count, used: 0, limit: nil)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.badge(label: "Pay as you go", text: "2500 cap", colorHex: "#22c55e")]
            )
        )
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]), providers: [runtime])

        await store.refreshAll()

        XCTAssertEqual(store.data(for: descriptor).valueText, "2500 cap")
    }
}

private final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

private func billingBody(used: Any, monthlyLimit: Any, onDemandCap: Any) -> Data {
    let body: [String: Any] = [
        "config": [
            "used": ["val": used],
            "monthlyLimit": ["val": monthlyLimit],
            "onDemandCap": ["val": onDemandCap],
            "billingPeriodEnd": "2026-06-01T00:00:00+00:00"
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: body)
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt)
}

private func badge(_ lines: [MetricLine], _ label: String) -> (text: String, colorHex: String?)? {
    guard case .badge(_, let text, let colorHex, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (text, colorHex)
}

private func makeJWT(exp: Int) -> String {
    let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
    let payload = base64URL(Data(#"{"exp":\#(exp)}"#.utf8))
    return "\(header).\(payload).signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
