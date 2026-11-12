import Foundation
import Security

public enum Credential: String, Sendable, CaseIterable {
    case elevenLabsAPIKey = "elevenlabs-api-key"
    case geminiAPIKey = "gemini-api-key"
    case selfHostedToken = "self-hosted-token"
    /// Optional bearer token for the self-hosted OpenAI-compatible summary server.
    case openAICompatibleAPIKey = "openai-compatible-api-key"
    /// OAuth refresh tokens for the dashboard's calendar sources.
    case googleCalendarRefreshToken = "google-calendar-refresh-token"
    case microsoftCalendarRefreshToken = "microsoft-calendar-refresh-token"
}

public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return String(localized: "Couldn't access the keychain: \(reason)", bundle: .main)
    }
}

/// Generic-password items, one per `Credential`, readable only on this Mac.
///
/// Builds signed with a provisioning profile keep them in the data protection keychain, which
/// gates access by the team's keychain access group: every profile-signed build of the app reads
/// them without a prompt, across updates and across Developer ID and development signing.
/// Builds without that entitlement (ad-hoc contributor builds) fall back to the login keychain,
/// whose per-item ACL trusts only the signing requirement of the build that created the item.
/// The first entitled read moves a login-keychain item into the data protection keychain (macOS
/// may ask once for that). Each credential is read from the keychain at most once per store;
/// later reads come from memory.
public final class KeychainCredentialStore: @unchecked Sendable {
    public static let defaultService = "app.mm2t.credentials"
    public let service: String

    private let modern: any KeychainItems
    private let legacy: any KeychainItems
    private let lock = NSLock()
    // Guarded by `lock`.
    private var cache: [Credential: Secret?] = [:]
    private var modernAvailable: Bool?

    public convenience init(service: String = KeychainCredentialStore.defaultService) {
        self.init(service: service,
                  modern: SecItems(service: service, dataProtection: true),
                  legacy: SecItems(service: service, dataProtection: false))
    }

    init(service: String, modern: any KeychainItems, legacy: any KeychainItems) {
        self.service = service
        self.modern = modern
        self.legacy = legacy
    }

    public func read(_ credential: Credential) throws -> Secret? {
        try lock.withLock {
            if let cached = cache[credential] { return cached }
            let secret = try load(credential)
            cache[credential] = secret
            return secret
        }
    }

    /// Saving an empty secret deletes the item, so clearing a settings field clears the keychain.
    public func save(_ secret: Secret, for credential: Credential) throws {
        try lock.withLock {
            guard !secret.isEmpty else { return try remove(credential) }
            let data = Data(secret.revealed.utf8)
            let label = Self.label(credential)
            if try withModern({ try $0.write(data, label: label, account: credential.rawValue) }) == nil {
                try legacy.write(data, label: label, account: credential.rawValue)
            }
            cache[credential] = secret
        }
    }

    public func delete(_ credential: Credential) throws {
        try lock.withLock { try remove(credential) }
    }

    private func load(_ credential: Credential) throws -> Secret? {
        let account = credential.rawValue
        guard let stored = try withModern({ try $0.read(account) }) else {
            return try legacy.read(account).flatMap(Self.secret)
        }
        if let stored { return Self.secret(stored) }
        // Not in the data protection keychain yet: move a login-keychain item over, once.
        guard try legacy.exists(account), let data = try legacy.read(account) else { return nil }
        let moved: Void? = try? withModern { try $0.write(data, label: Self.label(credential), account: account) }
        if moved != nil { try? legacy.delete(account) }
        return Self.secret(data)
    }

    /// Clears both keychains, so a deleted key can't come back through the migration.
    private func remove(_ credential: Credential) throws {
        let account = credential.rawValue
        _ = try withModern { try $0.delete(account) }
        if try legacy.exists(account) { try legacy.delete(account) }
        cache[credential] = .some(nil)
    }

    /// Runs `body` on the data protection keychain; nil when this build isn't entitled to it.
    /// An unentitled build finds nothing there and is refused only when it writes, so the first
    /// refused write switches this store to the login keychain.
    private func withModern<T>(_ body: (any KeychainItems) throws -> T) throws -> T? {
        guard modernAvailable != false else { return nil }
        do {
            let result = try body(modern)
            modernAvailable = true
            return result
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            modernAvailable = false
            return nil
        }
    }

    private static func label(_ credential: Credential) -> String { "mm2t \(credential.rawValue)" }

    private static func secret(_ data: Data) -> Secret? {
        String(data: data, encoding: .utf8).map { Secret($0) }
    }
}

/// Raw generic-password operations on one keychain implementation, keyed by account.
protocol KeychainItems: Sendable {
    func read(_ account: String) throws -> Data?
    /// Looks at attributes only, so it never asks the user for access.
    func exists(_ account: String) throws -> Bool
    func write(_ data: Data, label: String, account: String) throws
    func delete(_ account: String) throws
}

struct SecItems: KeychainItems {
    let service: String
    let dataProtection: Bool

    func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    func exists(_ account: String) throws -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }

    func write(_ data: Data, label: String, account: String) throws {
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = label
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}

/// Result of the settings screen's "verify" button.
public enum KeyCheck: Equatable, Sendable {
    case valid
    /// The service answered and refused the key; `message` says what to do.
    case rejected(String)
    /// The check could not reach a verdict (offline, rate limited, server down).
    case inconclusive(String)

    static func from(_ error: ProviderError) -> KeyCheck {
        switch error.kind {
        case .invalidCredential, .permissionDenied, .outOfCredit: .rejected(error.description)
        default: .inconclusive(error.description)
        }
    }
}
