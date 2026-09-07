import Foundation

public enum VeniceUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case anonymousSession
    case expiredSession
    case missingQuota
    case networkError(String)
    case apiError(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Venice Chrome session cookie not found. Sign in to venice.ai in Chrome."
        case .invalidCredentials:
            "Venice Chrome session is invalid or expired. Sign in to venice.ai again."
        case .anonymousSession:
            "Venice Chrome session is anonymous and has no subscription quota."
        case .expiredSession:
            "Venice Chrome session token is expired. Sign in to venice.ai again."
        case .missingQuota:
            "Venice Chrome session did not include subscription quota."
        case let .networkError(message):
            "Venice network error: \(message)"
        case let .apiError(status):
            "Venice session API returned status \(status)."
        case let .parseFailed(message):
            "Could not parse Venice session: \(message)"
        }
    }

    public var isAuthRelated: Bool {
        switch self {
        case .missingCredentials, .invalidCredentials, .anonymousSession, .expiredSession:
            true
        default:
            false
        }
    }
}
