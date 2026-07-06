import Foundation

enum MiniMaxAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY."
        case .sessionExpired:
            return "Session expired. Check your MiniMax API key."
        }
    }
}

/// Whether to hit the GLOBAL (minimax.io) or CN (minimaxi.com) endpoint. AUTO picks based on which
/// key is present — the CN key takes precedence.
enum MiniMaxEndpoint: String, Sendable {
    case global
    case cn

    var usageURLs: [URL] {
        switch self {
        case .global:
            return [URL(string: "https://www.minimax.io/v1/token_plan/remains")!]
        case .cn:
            return [URL(string: "https://api.minimaxi.com/v1/token_plan/remains")!]
        }
    }

    var envVars: [String] {
        switch self {
        case .global:
            return ["MINIMAX_API_KEY", "MINIMAX_API_TOKEN"]
        case .cn:
            return ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY", "MINIMAX_API_TOKEN"]
        }
    }

    /// CN returns model-call counts (15 per prompt); GLOBAL returns prompt counts directly.
    var displayDivisor: Double {
        self == .cn ? 15.0 : 1.0
    }
}

/// Reads the MiniMax API key from the environment. In AUTO mode the presence of `MINIMAX_CN_API_KEY`
/// routes to the CN endpoint first; otherwise GLOBAL.
struct MiniMaxAuthStore: Sendable {
    var environment: EnvironmentReading

    init(environment: EnvironmentReading = ProcessEnvironmentReader()) {
        self.environment = environment
    }

    /// The endpoints to try, in order. CN first when its key is set, otherwise GLOBAL first.
    func endpointOrder() -> [MiniMaxEndpoint] {
        let hasCnKey = environment.value(for: "MINIMAX_CN_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasCnKey ? [.cn, .global] : [.global, .cn]
    }

    func loadApiKey(endpoint: MiniMaxEndpoint) -> String? {
        for name in endpoint.envVars {
            if let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
