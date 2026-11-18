import Foundation
import Testing
@testable import MM2TProviders

/// Runs against the real login keychain under a throwaway service name.
@Suite(.serialized) struct KeychainCredentialStoreTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_KEYCHAIN_TESTS"] == "1"))
    func storesUpdatesAndDeletesEachCredentialSeparately() throws {
        let store = KeychainCredentialStore(service: "app.mm2t.tests.\(UUID().uuidString)")
        defer { for credential in Credential.allCases { try? store.delete(credential) } }

        #expect(try store.read(.geminiAPIKey) == nil)

        try store.save("AIza-first", for: .geminiAPIKey)
        try store.save("xi-key", for: .elevenLabsAPIKey)
        #expect(try store.read(.geminiAPIKey) == "AIza-first")
        #expect(try store.read(.elevenLabsAPIKey) == "xi-key")
        #expect(try store.read(.selfHostedToken) == nil)

        try store.save("  AIza-second\n", for: .geminiAPIKey)
        #expect(try store.read(.geminiAPIKey) == "AIza-second")

        try store.save("", for: .geminiAPIKey)
        #expect(try store.read(.geminiAPIKey) == nil)
        try store.delete(.geminiAPIKey)

        try store.delete(.elevenLabsAPIKey)
        #expect(try store.read(.elevenLabsAPIKey) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MM2T_KEYCHAIN_TESTS"] == "1"))
    func storesAreIsolatedByServiceName() throws {
        let a = KeychainCredentialStore(service: "app.mm2t.tests.\(UUID().uuidString)")
        let b = KeychainCredentialStore(service: "app.mm2t.tests.\(UUID().uuidString)")
        defer { try? a.delete(.selfHostedToken) }

        try a.save("token-a", for: .selfHostedToken)
        #expect(try b.read(.selfHostedToken) == nil)
    }

    @Test func secretsNeverPrint() {
        let secret = Secret("sk-very-secret")
        #expect(!"\(secret)".contains("very"))
        #expect(!String(reflecting: secret).contains("very"))
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("very"))
    }
}
