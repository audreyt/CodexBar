import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GrokTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"

    public enum RefreshError: LocalizedError, Sendable {
        case missingRefreshToken
        case rejected
        case networkError(Error)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .missingRefreshToken:
                "Grok credentials have no refresh token. Run `grok login` to authenticate again."
            case .rejected:
                "Grok refresh token was rejected. Run `grok login` to authenticate again."
            case let .networkError(error):
                "Network error during Grok token refresh: \(error.localizedDescription)"
            case let .invalidResponse(message):
                "Invalid Grok token refresh response: \(message)"
            }
        }
    }

    public static func refresh(_ credentials: GrokCredentials) async throws -> GrokCredentials {
        try await self.refresh(
            credentials,
            session: ProviderHTTPClient.shared,
            now: Date())
    }

    static func refresh(
        _ credentials: GrokCredentials,
        session transport: any ProviderHTTPTransport,
        now: Date = Date()) async throws -> GrokCredentials
    {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw RefreshError.missingRefreshToken
        }

        var request = URLRequest(
            url: Self.refreshEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        do {
            let response = try await transport.response(for: request)
            guard response.statusCode == 200 else {
                if response.statusCode == 400 || response.statusCode == 401 {
                    throw RefreshError.rejected
                }
                throw RefreshError.invalidResponse("HTTP \(response.statusCode)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw RefreshError.invalidResponse("Invalid JSON")
            }
            guard let accessToken = Self.nonEmptyString(json["access_token"]) else {
                throw RefreshError.invalidResponse("Missing access_token")
            }
            guard let expiresIn = Self.expiresIn(from: json["expires_in"]), expiresIn > 0 else {
                throw RefreshError.invalidResponse("Missing expires_in")
            }
            let newRefreshToken = Self.nonEmptyString(json["refresh_token"]) ?? refreshToken

            return GrokCredentials(
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                scope: credentials.scope,
                authMode: credentials.authMode,
                userId: credentials.userId,
                email: credentials.email,
                firstName: credentials.firstName,
                lastName: credentials.lastName,
                teamId: credentials.teamId,
                oidcIssuer: credentials.oidcIssuer,
                oidcClientId: credentials.oidcClientId,
                expiresAt: now.addingTimeInterval(expiresIn),
                createTime: now)
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.networkError(error)
        }
    }

    static func refreshStoredCredentialsIfNeeded(
        env: [String: String] = ProcessInfo.processInfo.environment) async throws -> GrokCredentials?
    {
        let credentials: GrokCredentials
        do {
            credentials = try GrokCredentialsStore.load(env: env)
        } catch GrokCredentialsError.notFound {
            return nil
        }
        guard credentials.needsRefresh,
              credentials.scope.hasPrefix(GrokCredentialsStore.oidcScopePrefix),
              credentials.refreshToken != nil
        else {
            return credentials
        }

        let refreshed = try await self.refresh(credentials)
        try GrokCredentialsStore.save(refreshed, env: env)
        return refreshed
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return string
    }

    private static func expiresIn(from value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return TimeInterval(string)
        }
        return nil
    }
}
