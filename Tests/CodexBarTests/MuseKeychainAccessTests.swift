#if os(macOS)
import Foundation
import Security
import Testing
@testable import CodexBarCore

/// The Muse CLI owns its legacy Keychain item, so a secret read that its access list does not allow shows a
/// blocking Allow/Deny prompt. These tests pin when CodexBar may request that secret.
struct MuseKeychainAccessTests {
    @Test(arguments: [KeychainAccessPreflight.Outcome.interactionRequired, .temporarilyUnavailable, .failure(-1)])
    func `background refresh never requests a secret macOS would have to ask for`(
        outcome: KeychainAccessPreflight.Outcome) throws
    {
        let run = try Self.fetchToken(outcome: outcome, interaction: .background)
        #expect(run.error == .keychainUnavailable)
        #expect(run.events.isEmpty)
    }

    @Test
    func `user-initiated refresh explains before macOS asks for the Muse login`() throws {
        let run = try Self.fetchToken(outcome: .interactionRequired, interaction: .userInitiated)
        #expect(run.token == "dca:fixture-keychain")
        #expect(run.events == ["explain museOAuth", "read interactive"])
    }

    @Test
    func `user-initiated read that cannot be explained never prompts`() throws {
        let run = try Self.fetchToken(outcome: .interactionRequired, interaction: .userInitiated, canExplain: false)
        #expect(run.error == .keychainUnavailable)
        #expect(run.events.isEmpty)
    }

    @Test(arguments: [ProviderInteraction.background, .userInitiated])
    func `trusted item is read without UI or an explanation`(interaction: ProviderInteraction) throws {
        let run = try Self.fetchToken(outcome: .allowed, interaction: interaction)
        #expect(run.token == "dca:fixture-keychain")
        #expect(run.events == ["read no-ui"])
    }

    @Test(arguments: zip(
        [KeychainAccessPreflight.Outcome.allowed, .interactionRequired, .notFound],
        [true, true, false]))
    func `login detection never requests the secret`(outcome: KeychainAccessPreflight.Outcome, expected: Bool) throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let events = LockIsolated<[String]>([])
        let hasLogin = Self.withSyntheticKeychain(outcome: outcome, interaction: .userInitiated, events: events) {
            MuseCredentials.hasLogin(environment: [:], homeDirectory: home)
        }
        #expect(hasLogin == expected)
        #expect(events.value.isEmpty)
    }

    private struct Run {
        var token: String?
        var error: MuseUsageError?
        var events: [String] = []
    }

    /// Fetches the token for a Keychain-backed CLI login whose item reports `outcome` from the no-UI ACL preflight.
    private static func fetchToken(
        outcome: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction,
        canExplain: Bool = true) throws -> Run
    {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("auth.json")
        try Data(#"{"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#.utf8).write(to: file)
        let events = LockIsolated<[String]>([])
        var run = Run()
        Self.withSyntheticKeychain(outcome: outcome, interaction: interaction, events: events, canExplain: canExplain) {
            do {
                run.token = try MuseCredentials.accessToken(
                    environment: ["MUSE_AUTH_PATH": file.path],
                    homeDirectory: home)
            } catch let error as MuseUsageError {
                run.error = error
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        run.events = events.value
        return run
    }

    /// Records explanation alerts and secret reads in order; no real Keychain item is touched.
    private static func withSyntheticKeychain<T>(
        outcome: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction,
        events: LockIsolated<[String]>,
        canExplain: Bool = true,
        operation: () -> T) -> T
    {
        let record: @Sendable (String) -> Void = { events.setValue(events.value + [$0]) }
        let read: @Sendable (Bool) -> (OSStatus, Data?) = { allowsInteraction in
            record(allowsInteraction ? "read interactive" : "read no-ui")
            return (errSecSuccess, Data(#"{"access_token":"dca:fixture-keychain"}"#.utf8))
        }
        return KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { service, account in
                #expect(service == MuseCredentials.keychainService)
                #expect(account == MuseCredentials.keychainAccount)
                return outcome
            } operation: {
                KeychainPromptHandler.withHandlerForTesting(canExplain ? { record("explain \($0.kind)") } : nil) {
                    MuseCredentials.$keychainReadOverrideForTesting.withValue(read) {
                        ProviderInteractionContext.$current.withValue(interaction, operation: operation)
                    }
                }
            }
        }
    }

    private static func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}
#endif
