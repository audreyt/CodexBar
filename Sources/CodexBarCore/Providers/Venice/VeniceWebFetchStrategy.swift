import Foundation

/// A Venice web session resolved from imported browser cookies.
public struct VeniceResolvedSession: Sendable {
    public let cookieHeader: String
    public let sourceLabel: String

    public init(cookieHeader: String, sourceLabel: String) {
        self.cookieHeader = cookieHeader
        self.sourceLabel = sourceLabel
    }
}

/// Explicit-web-only strategy for Venice subscription quota via the signed-in
/// venice.ai session. Unlike the API-key script strategy, this never runs in
/// automatic mode: importing browser cookies can surface an OS permission
/// prompt, so it only runs when the caller explicitly selects the web source.
struct VeniceWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (String) async throws -> UsageSnapshot
    typealias SessionLoader = @Sendable () throws -> [VeniceResolvedSession]

    let id: String = "venice.web"
    let kind: ProviderFetchKind = .web

    private let usageLoader: UsageLoader
    private let sessionLoader: SessionLoader

    init(
        usageLoader: @escaping UsageLoader = { try await VeniceWebUsageFetcher.fetchUsage(cookieHeader: $0) },
        sessionLoader: @escaping SessionLoader = { try Self.defaultSessions() })
    {
        self.usageLoader = usageLoader
        self.sessionLoader = sessionLoader
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.sourceMode == .web else { return false }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard context.sourceMode == .web else { throw VeniceUsageError.missingCredentials }
        guard let session = try self.sessionLoader().first else {
            throw VeniceUsageError.missingCredentials
        }
        let usage = try await self.usageLoader(session.cookieHeader)
        return self.makeResult(usage: usage, sourceLabel: session.sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    #if os(macOS)
    private static func defaultSessions() throws -> [VeniceResolvedSession] {
        try VeniceCookieImporter.importSessions().map {
            VeniceResolvedSession(cookieHeader: $0.cookieHeader, sourceLabel: $0.sourceLabel)
        }
    }
    #else
    private static func defaultSessions() throws -> [VeniceResolvedSession] {
        []
    }
    #endif
}
