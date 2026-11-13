import Foundation
import Security
import Testing
@testable import MM2TProviders

/// In-memory keychains, so the routing between the data protection and login keychains is
/// tested without touching the real ones.
@Suite struct CredentialStoreMigrationTests {
    @Test func movesALoginKeychainItemIntoTheDataProtectionKeychainOnce() throws {
        let modern = FakeItems(), legacy = FakeItems(["gemini-api-key": "AIza-old"])
        let store = KeychainCredentialStore(service: "test", modern: modern, legacy: legacy)

        #expect(try store.read(.geminiAPIKey) == "AIza-old")
        #expect(modern.items["gemini-api-key"] == "AIza-old")
        #expect(legacy.items["gemini-api-key"] == nil)

        let relaunched = KeychainCredentialStore(service: "test", modern: modern, legacy: legacy)
        #expect(try relaunched.read(.geminiAPIKey) == "AIza-old")
        #expect(legacy.reads == 1)
    }

    @Test func readsEachCredentialFromTheKeychainOncePerLaunch() throws {
        let modern = FakeItems(["elevenlabs-api-key": "xi"]), legacy = FakeItems()
        let store = KeychainCredentialStore(service: "test", modern: modern, legacy: legacy)

        for _ in 0..<3 {
            #expect(try store.read(.elevenLabsAPIKey) == "xi")
            #expect(try store.read(.selfHostedToken) == nil)
        }
        #expect(modern.reads == 2)
    }

    @Test func savesAreServedFromMemoryAfterwards() throws {
        let modern = FakeItems(), legacy = FakeItems()
        let store = KeychainCredentialStore(service: "test", modern: modern, legacy: legacy)

        try store.save(" AIza-new\n", for: .geminiAPIKey)
        #expect(try store.read(.geminiAPIKey) == "AIza-new")
        #expect(modern.items["gemini-api-key"] == "AIza-new")
        #expect(modern.reads == 0)
    }

    @Test func buildsWithoutTheEntitlementKeepUsingTheLoginKeychain() throws {
        let modern = FakeItems(entitled: false), legacy = FakeItems(["self-hosted-token": "tok"])
        let store = KeychainCredentialStore(service: "test", modern: modern, legacy: legacy)

        #expect(try store.read(.selfHostedToken) == "tok")
        try store.save("AIza", for: .geminiAPIKey)
        #expect(legacy.items == ["self-hosted-token": "tok", "gemini-api-key": "AIza"])
        try store.delete(.selfHostedToken)
        #expect(legacy.items["self-hosted-token"] == nil)
        #expect(modern.writeAttempts == 1)
        #expect(modern.items.isEmpty)
    }

    @Test func deletingClearsBothKeychainsSoTheMigrationCannotBringItBack() throws {
        let modern = FakeItems(["gemini-api-key": "new"]), legacy = FakeItems(["gemini-api-key": "stale"])
        let store = KeychainCredentialStore(service: "test", modern: modern, legacy: legacy)

        try store.save("", for: .geminiAPIKey)
        #expect(try store.read(.geminiAPIKey) == nil)
        #expect(try KeychainCredentialStore(service: "test", modern: modern, legacy: legacy).read(.geminiAPIKey) == nil)
    }

    @Test func aFailedMoveKeepsTheLoginKeychainItem() throws {
        let modern = FakeItems(), legacy = FakeItems(["gemini-api-key": "AIza-old"])
        modern.failWrites = true
        let store = KeychainCredentialStore(service: "test", modern: modern, legacy: legacy)

        #expect(try store.read(.geminiAPIKey) == "AIza-old")
        #expect(legacy.items["gemini-api-key"] == "AIza-old")
    }
}

private final class FakeItems: KeychainItems, @unchecked Sendable {
    private let lock = NSLock()
    private let entitled: Bool
    private var stored: [String: String]
    private var readCount = 0, attemptCount = 0
    var failWrites = false

    init(_ items: [String: String] = [:], entitled: Bool = true) {
        stored = items
        self.entitled = entitled
    }

    var items: [String: String] { lock.withLock { stored } }
    var reads: Int { lock.withLock { readCount } }
    var writeAttempts: Int { lock.withLock { attemptCount } }

    func read(_ account: String) throws -> Data? {
        lock.withLock {
            readCount += 1
            return stored[account].map { Data($0.utf8) }
        }
    }

    func exists(_ account: String) throws -> Bool { lock.withLock { stored[account] != nil } }

    /// Like the real data protection keychain, an unentitled process is refused only on writes.
    func write(_ data: Data, label: String, account: String) throws {
        try lock.withLock {
            attemptCount += 1
            guard entitled else { throw KeychainError(status: errSecMissingEntitlement) }
            if failWrites { throw KeychainError(status: errSecIO) }
            stored[account] = String(decoding: data, as: UTF8.self)
        }
    }

    func delete(_ account: String) throws { lock.withLock { stored[account] = nil } }
}
