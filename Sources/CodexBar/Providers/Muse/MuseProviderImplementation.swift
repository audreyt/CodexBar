import CodexBarCore
import Foundation

struct MuseProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .muse

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "oauth" }
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        MuseCredentials.hasLogin(environment: context.environment)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "muse-cookie-header",
            title: "Cookie header",
            subtitle: "Paste a Cookie header from dev.meta.ai. Its account must match your Muse CLI login.",
            kind: .secure,
            placeholder: "Cookie: …",
            binding: context.providerConfigBinding(.cookieHeader),
            actions: [.openURL(
                id: "muse-open-usage",
                title: "Open Muse Code Usage",
                url: URL(string: "https://dev.meta.ai/usage"))],
            isVisible: { context.settings.museCookieSource == .manual })]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [ProviderCookieSourceUI.picker(
            id: "muse-cookie-source",
            context: context,
            source: \.museCookieSource,
            allowsOff: true,
            subtitles: {
                .init(
                    auto: "Use a signed-in Meta dashboard session when the CLI endpoint omits quota.",
                    manual: "Paste a Cookie header from https://dev.meta.ai/usage when the CLI endpoint omits quota.",
                    off: "Only use quota reported by the Muse CLI endpoint.")
            })]
    }
}

extension SettingsStore {
    var museCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .muse, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .muse) }
    }
}
