import Foundation

enum MiniMaxUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case requestFailed(Int)
    case unparseable
    /// MiniMax's own `base_resp` error (non-zero status_code that isn't an auth signal). Carries the
    /// API's message text so it surfaces verbatim, per the project's fail-loudly rule.
    case apiStatus(Int)
    case apiMessage(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Request failed. Check your connection."
        case .requestFailed(let statusCode):
            return "Request failed (HTTP \(statusCode)). Try again later."
        case .unparseable:
            return "Could not parse usage data."
        case .apiStatus(let statusCode):
            return "MiniMax API error (status \(statusCode))."
        case .apiMessage(let message):
            return "MiniMax API error: \(message)"
        }
    }
}

/// Tries each candidate URL for the endpoint in order, returning the first usable JSON body.
/// Mirrors the JS plugin's multi-URL fallback so a CDN/regional hiccup doesn't blank the tile.
struct MiniMaxUsageClient: Sendable {
    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    struct FetchOutcome {
        let response: HTTPResponse
        let authStatusCount: Int
        let requestFailedStatus: Int?
        let hadNetworkError: Bool
    }

    func fetchUsage(endpoint: MiniMaxEndpoint, apiKey: String) async -> FetchOutcome {
        var authStatusCount = 0
        var requestFailedStatus: Int?
        var hadNetworkError = false

        for url in endpoint.usageURLs {
            do {
                let response = try await httpClient.send(HTTPRequest(
                    method: "GET",
                    url: url,
                    headers: [
                        "Authorization": "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                        "Content-Type": "application/json",
                        "Accept": "application/json"
                    ],
                    timeout: 15
                ))

                if ProviderAuthRetry.isAuthFailure(response) {
                    authStatusCount += 1
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    requestFailedStatus = response.statusCode
                    continue
                }

                // A 2xx with parseable JSON is a hit.
                if ProviderParse.jsonObject(response.body) != nil {
                    return FetchOutcome(response: response, authStatusCount: authStatusCount, requestFailedStatus: requestFailedStatus, hadNetworkError: hadNetworkError)
                }
            } catch {
                hadNetworkError = true
                AppLog.warn(LogTag.plugin("minimax"), "request failed (\(url)): \(error.localizedDescription)")
            }
        }

        // No usable response. Return the last response seen (or a synthesized 0) so the mapper can
        // triage auth vs request-failure vs network.
        let lastResponse = HTTPResponse(statusCode: requestFailedStatus ?? 0, headers: [:], body: Data())
        return FetchOutcome(response: lastResponse, authStatusCount: authStatusCount, requestFailedStatus: requestFailedStatus, hadNetworkError: hadNetworkError)
    }

    /// Interpret the fetch outcome into the error the user should see (when no endpoint succeeded).
    static func error(for outcome: FetchOutcome) -> Error {
        if outcome.authStatusCount > 0 && outcome.requestFailedStatus == nil && !outcome.hadNetworkError {
            return MiniMaxAuthError.sessionExpired
        }
        if let status = outcome.requestFailedStatus {
            return MiniMaxUsageError.requestFailed(status)
        }
        if outcome.hadNetworkError {
            return MiniMaxUsageError.connectionFailed
        }
        return MiniMaxUsageError.unparseable
    }
}
