import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse Code",
                sessionLabel: "5 hours",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Muse Code subscription 5-hour and weekly windows.",
                toggleTitle: "Show Muse Code usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                dashboardURL: "https://dev.meta.ai",
                subscriptionDashboardURL: "https://dev.meta.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 6 / 255, green: 104 / 255, blue: 225 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0668E1),
                    ProviderColor(hex: 0x8B5CF6),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Muse Code subscription usage is reported as 5-hour and weekly windows." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MuseOAuthFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["muse-code"],
                versionDetector: nil))
    }
}

struct MuseOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "muse.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        MuseCredentials.hasLogin(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let token = try MuseCredentials.accessToken(environment: context.env)
        let snapshot = try await MuseUsageFetcher.fetchUsage(accessToken: token)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "oauth")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
