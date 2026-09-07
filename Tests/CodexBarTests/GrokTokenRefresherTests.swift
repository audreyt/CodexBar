import Foundation
import Testing
@testable import CodexBarCore

struct GrokTokenRefresherTests {
    @Test
    func `refresh sends OAuth form and rotates credentials`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let responseBody = Data(
            #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":21600}"#.utf8)
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://auth.x.ai/oauth2/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
            let components = URLComponents(string: "?\(body)")
            let fields = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            #expect(fields["client_id"] == "b1a00492-073a-47ea-816f-4c329264a828")
            #expect(fields["grant_type"] == "refresh_token")
            #expect(fields["refresh_token"] == "old-refresh")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (responseBody, response)
        }

        let refreshed = try await GrokTokenRefresher.refresh(
            Self.credentials(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expiresAt: now),
            session: transport,
            now: now)

        #expect(refreshed.accessToken == "fresh-access")
        #expect(refreshed.refreshToken == "fresh-refresh")
        #expect(refreshed.createTime == now)
        #expect(refreshed.expiresAt == now.addingTimeInterval(21600))
        #expect(refreshed.email == "user@example.com")
    }

    @Test
    func `refresh preserves refresh token when server omits rotation`() async throws {
        let responseBody = Data(#"{"access_token":"fresh-access","expires_in":"3600"}"#.utf8)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (responseBody, response)
        }

        let refreshed = try await GrokTokenRefresher.refresh(
            Self.credentials(refreshToken: "stable-refresh"),
            session: transport,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(refreshed.refreshToken == "stable-refresh")
        #expect(refreshed.expiresAt == Date(timeIntervalSince1970: 1_800_003_600))
    }

    @Test
    func `refresh rejects unusable token responses`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"error":"invalid_grant"}"#.utf8), response)
        }

        await #expect(throws: GrokTokenRefresher.RefreshError.self) {
            _ = try await GrokTokenRefresher.refresh(
                Self.credentials(refreshToken: "revoked-refresh"),
                session: transport)
        }
    }

    @Test
    func `expired credentials need refresh`() {
        #expect(Self.credentials(expiresAt: Date().addingTimeInterval(-10)).needsRefresh)
        #expect(Self.credentials(expiresAt: Date().addingTimeInterval(60)).needsRefresh)
        #expect(!Self.credentials(expiresAt: Date().addingTimeInterval(3600)).needsRefresh)
        #expect(!Self.credentials(expiresAt: nil).needsRefresh)
        #expect(!Self.credentials(refreshToken: nil).needsRefresh)
        #expect(!Self.credentials(refreshToken: "  ").needsRefresh)
    }

    @Test
    func `save merges refreshed tokens without dropping sibling scopes`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokTokenRefresherTests-\(UUID().uuidString)")
        let env = ["GROK_HOME": home.path]
        let scope = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
        let existing = """
        {"\(scope)":{"key":"old-access","refresh_token":"old-refresh","custom_field":"keep-me"},\
        "https://accounts.x.ai/sign-in":{"key":"legacy-access"}}
        """
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(existing.utf8).write(to: home.appendingPathComponent("auth.json"))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try GrokCredentialsStore.save(
            Self.credentials(
                accessToken: "fresh-access",
                refreshToken: "fresh-refresh",
                expiresAt: now),
            env: env)

        let reloaded = try GrokCredentialsStore.load(env: env)
        #expect(reloaded.accessToken == "fresh-access")
        #expect(reloaded.refreshToken == "fresh-refresh")
        #expect(reloaded.expiresAt == now)
        #expect(reloaded.email == "user@example.com")
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("auth.json"))) as? [String: Any]
        let entry = raw?[scope] as? [String: Any]
        #expect(entry?["custom_field"] as? String == "keep-me")
        #expect((raw?["https://accounts.x.ai/sign-in"] as? [String: Any])?["key"] as? String == "legacy-access")
    }

    @Test
    func `refreshStoredCredentialsIfNeeded returns nil without an auth file`() async throws {
        let env = ["GROK_HOME": FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokTokenRefresherTests-missing-\(UUID().uuidString)").path]
        let result = try await GrokTokenRefresher.refreshStoredCredentialsIfNeeded(env: env)
        #expect(result?.accessToken == nil)
    }

    private static func credentials(
        accessToken: String = "access-token",
        refreshToken: String? = "refresh-token",
        expiresAt: Date? = Date(timeIntervalSince1970: 1_900_000_000)) -> GrokCredentials
    {
        GrokCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            scope: "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828",
            authMode: "oidc",
            userId: "user-id",
            email: "user@example.com",
            firstName: "Ada",
            lastName: "Lovelace",
            teamId: "team-id",
            oidcIssuer: "https://auth.x.ai",
            oidcClientId: "b1a00492-073a-47ea-816f-4c329264a828",
            expiresAt: expiresAt,
            createTime: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
