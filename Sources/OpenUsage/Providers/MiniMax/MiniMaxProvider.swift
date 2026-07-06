import Foundation

@MainActor
final class MiniMaxProvider: ProviderRuntime {
    let provider = Provider(id: "minimax", displayName: "MiniMax", icon: .providerMark("minimax"))

    let authStore: MiniMaxAuthStore
    let usageClient: MiniMaxUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: MiniMaxAuthStore = MiniMaxAuthStore(),
        usageClient: MiniMaxUsageClient = MiniMaxUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "minimax.session", provider: provider, title: "Session", metricLabel: "Session")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        do {
            return try await loadAndProbe()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadAndProbe() async throws -> ProviderSnapshot {
        let endpointOrder = authStore.endpointOrder()

        var lastError: Error?
        for endpoint in endpointOrder {
            guard let apiKey = authStore.loadApiKey(endpoint: endpoint) else {
                continue
            }
            let outcome = await usageClient.fetchUsage(endpoint: endpoint, apiKey: apiKey)
            guard let body = ProviderParse.jsonObject(outcome.response.body) else {
                if outcome.authStatusCount > 0 || outcome.requestFailedStatus != nil || outcome.hadNetworkError {
                    lastError = MiniMaxUsageClient.error(for: outcome)
                } else {
                    lastError = MiniMaxUsageError.unparseable
                }
                continue
            }

            do {
                if let parsed = try MiniMaxUsageMapper.parse(body: body, endpoint: endpoint, now: now()) {
                    let mapped = MiniMaxUsageMapper.makeUsage(parsed: parsed, endpoint: endpoint)
                    return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
                }
                if lastError == nil { lastError = MiniMaxUsageError.unparseable }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? MiniMaxAuthError.notLoggedIn
    }
}
