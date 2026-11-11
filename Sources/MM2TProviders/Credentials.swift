import Foundation
import Security

public enum Credential: String, Sendable, CaseIterable {
    case elevenLabsAPIKey = "elevenlabs-api-key"
    case geminiAPIKey = "gemini-api-key"
    case selfHostedToken = "self-hosted-token"
    /// OAuth refresh tokens for the dashboard's calendar sources.
    case googleCalendarRefreshToken = "google-calendar-refresh-token"
    case microsoftCalendarRefreshToken = "microsoft-calendar-refresh-token"
}

public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "無法存取鑰匙圈：\(reason)"
    }
}

/// Generic-password items in the login keychain, one per `Credential`, readable only on this Mac.
public struct KeychainCredentialStore: Sendable {
    public static let defaultService = "app.mm2t.credentials"
    public let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func read(_ credential: Credential) throws -> Secret? {
        var query = baseQuery(credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return Secret(value)
    }

    /// Saving an empty secret deletes the item, so clearing a settings field clears the keychain.
    public func save(_ secret: Secret, for credential: Credential) throws {
        guard !secret.isEmpty else { return try delete(credential) }
        let data = Data(secret.revealed.utf8)
        let update = SecItemUpdate(baseQuery(credential) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = baseQuery(credential)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "mm2t \(credential.rawValue)"
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    public func delete(_ credential: Credential) throws {
        let status = SecItemDelete(baseQuery(credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ credential: Credential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
        ]
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
