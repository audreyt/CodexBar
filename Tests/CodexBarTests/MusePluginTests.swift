import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct MusePluginTests {
    static let account = #"""
    {
      "api_key":"LLM|fixture-inference-key", "payment_method":"Visa-0000",
      "require_payment":false, "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage",
      "subs_usage":{
        "window":{"used_percent":96,"window_duration_mins":300,"resets_at":1788599502},
        "weekly":{"used_percent":40,"resets_at":1788739200}
      }
    }
    """#

    static let activeWithoutWindows = #"""
    {"is_subs_active":true,"user_email":"ada@example.com","subs_tier_name":"Muse Code Power Usage"}
    """#

    static let activeWithNullWindows = #"""
    {
      "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage", "subs_usage":null
    }
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported subscription windows retain their identity and resets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.account, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_788_599_502))
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_788_739_200))
        #expect(snapshot.identity?.providerID == .muse)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.providerCost == nil)
        #expect(!snapshot.details.flatMap(\.rows).contains { $0.value.contains("Visa") || $0.value.contains("LLM|") })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `dashboard quota restores bars for the matching Muse login`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetchDashboard(mint: Self.activeWithoutWindows, engine: engine)
        let snapshot = result.snapshot
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(abs((snapshot.secondary?.usedPercent ?? -1) - (309_178_895_380.0 / 1_200_000_000_000.0 * 100)) < 0.0001)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_790_553_600))
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.dataConfidence == .exact)
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Plan" && $0.value == "Muse Code Power Usage" })
        #expect(rows.contains { $0.label == "5 hours" } && rows.contains { $0.label == "Weekly" })
        #expect(!rows.contains { $0.label == "Quota" })
        #expect(result.rejectedDomains.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `dashboard quota from a different account cannot replace CLI identity`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetchDashboard(
            mint: Self.activeWithoutWindows,
            engine: engine,
            responses: ["https://dev.meta.ai/api/auth/me": (200, #"{"email":"other@example.com"}"#)])
        Self.expectQuotaUnavailable(result.snapshot, reason: "does not match")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired dashboard session is rejected without failing the CLI login`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetchDashboard(
            mint: Self.activeWithoutWindows,
            engine: engine,
            responses: ["https://dev.meta.ai/api/auth/me": (401, "{}")])
        Self.expectQuotaUnavailable(result.snapshot, reason: "session expired")
        #expect(result.rejectedDomains == ["dev.meta.ai"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unrecognized dashboard quota keeps the CLI identity`(engine: ProviderPluginEngineKind) async throws {
        var responses = Self.dashboardResponses
        responses["https://dev.meta.ai/api/portal/teams/2143643292914226/subscription-quota"] = (
            200,
            Self.dashboardQuota.replacingOccurrences(of: #""1200000000000""#, with: #""-1""#))
        let result = try await Self.fetchDashboard(
            mint: Self.activeWithoutWindows,
            engine: engine,
            responses: responses)
        Self.expectQuotaUnavailable(result.snapshot, reason: "format was not recognized")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled dashboard cookies never reach the dashboard`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetchDashboard(
            mint: Self.activeWithoutWindows,
            engine: engine,
            responses: [:],
            cookieSource: .off)
        Self.expectQuotaUnavailable(result.snapshot, reason: "cookies are off")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported mint quota never consults the dashboard`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetchDashboard(mint: Self.account, engine: engine, responses: [:])
        #expect(result.snapshot.primary?.usedPercent == 96)
        #expect(result.snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `JSON request sends only the device credential and fixed API version`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.meta.ai/muse-code/key")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dca:fixture-token")
                #expect(request.value(forHTTPHeaderField: "x-api-version") == "1.0.0")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.timeoutInterval == 15)
                #expect(request.httpBody == Data("{}".utf8))
                return try Self.response(request, body: Self.account)
            })
        _ = try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `inference keys never reach the mint endpoint`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                Issue.record("Inference credential reached the transport")
                return try Self.response(request, body: Self.account)
            })
        await Self.expectFailure(.authenticationExpired) {
            try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "LLM|fixture-token"])
        }
    }

    @Test(arguments: ["{}", "<html>Sign in</html>", ""], BundledPluginTestSupport.engines)
    func `unauthorized text responses retain login recovery`(body: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(body, engine: engine, status: 401)
        }
    }

    @Test(arguments: [
        #"{"require_payment":true,"is_subs_active":false}"#,
        #"{"is_subs_active":false,"subs_usage":null}"#,
    ], BundledPluginTestSupport.engines)
    func `inactive subscriptions and missing billing never invent quotas`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.permissionDenied) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: [Self.activeWithoutWindows, Self.activeWithNullWindows], BundledPluginTestSupport.engines)
    func `active login without quota windows keeps plan identity`(
        body: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.dataConfidence == .unknown)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Plan" && $0.value == "Muse Code Power Usage" })
        #expect(rows.contains { $0.label == "Quota" && $0.value.contains("login response") })
        #expect(!rows.contains { $0.label == "5 hours" || $0.label == "Weekly" })
    }

    @Test(
        arguments: [#""window""#, "false", "[]", "{}"].map { #"{"is_subs_active":true,"subs_usage":\#($0)}"# },
        BundledPluginTestSupport.engines)
    func `non-object quota payload remains a parse failure`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: ["1e30", "0", "-1", "true", "\"300\""], BundledPluginTestSupport.engines)
    func `invalid durations fail without trapping`(value: String, engine: ProviderPluginEngineKind) async {
        let body = Self.account.replacingOccurrences(
            of: "\"window_duration_mins\":300",
            with: "\"window_duration_mins\":\(value)")
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unrepresentable resets preserve reported usage`(engine: ProviderPluginEngineKind) async throws {
        let body = Self.account.replacingOccurrences(of: "1788599502", with: "1e30")
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.secondary?.resetsAt != nil)
    }

    static let dashboardQuota = """
    {"subscription_quota":{"tier":"Muse Code Power Usage","as_of":1790072435,
      "window_weighted_limit":"400000000000","window_duration_secs":18000,
      "weekly_weighted_limit":"1200000000000","weekly_resets_at":1790553600,
      "window_weighted_used":"0","weekly_weighted_used":"309178895380"}}
    """

    static let dashboardResponses: [String: (Int, String)] = [
        "https://dev.meta.ai/api/auth/me": (200, #"{"email":"Ada@Example.com"}"#),
        "https://dev.meta.ai/api/portal/teams": (200, #"{"teams":[{"team_id":"2143643292914226"}]}"#),
        "https://dev.meta.ai/api/portal/teams/2143643292914226/subscription-quota": (200, Self.dashboardQuota),
    ]

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchUsage(
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: 1_788_580_000))
    }

    /// Unlisted dashboard URLs are recorded as failures, so an empty table proves no dashboard request was made.
    static func fetchDashboard(
        mint: String,
        engine: ProviderPluginEngineKind,
        responses: [String: (Int, String)] = Self.dashboardResponses,
        cookieSource: ProviderCookieSource = .auto) async throws -> (snapshot: UsageSnapshot, rejectedDomains: [String])
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url?.absoluteString)
                if url == "https://api.meta.ai/muse-code/key" {
                    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                    return try Self.response(request, body: mint)
                }
                #expect(request.value(forHTTPHeaderField: "Cookie") == "llama_dev_sess=synthetic")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                guard let (status, body) = responses[url] else {
                    Issue.record("Unexpected dashboard request \(url)")
                    return try Self.response(request, body: "{}", status: 404)
                }
                return try Self.response(request, body: body, status: status)
            })
        let rejected = LockIsolated<[String]>([])
        let snapshot = try await runtime.fetchUsage(
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: 1_788_580_000),
            cookieSource: cookieSource,
            cookieInvalidator: { rejected.setValue(rejected.value + [$0]) },
            cookieResolver: { provider, domain in
                #expect(provider == .muse)
                #expect(domain == "dev.meta.ai")
                return "llama_dev_sess=synthetic"
            })
        return (snapshot, rejected.value)
    }

    static func expectQuotaUnavailable(_ snapshot: UsageSnapshot, reason: String) {
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.dataConfidence == .unknown)
        #expect(snapshot.details.flatMap(\.rows).contains {
            $0.label == "Quota" && $0.secondaryValue?.contains(reason) == true
        })
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind.rawValue)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }
}
