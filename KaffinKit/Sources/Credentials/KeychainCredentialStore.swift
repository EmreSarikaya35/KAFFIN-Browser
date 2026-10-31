import BrowserCore
import Foundation
import Security

public struct KeychainError: Error {
    public let status: OSStatus
}

/// Keeps passwords in the macOS Keychain, one service per profile.
/// An actor, because Keychain calls block and must stay off the main thread.
public actor KeychainCredentialStore: CredentialStoring {
    private let service: String

    public init(profileID: UUID) {
        service = "com.kaffin.browser.logins.\(profileID.uuidString)"
    }

    private func query(for login: SavedLogin) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Origins never contain a newline, so the first one always separates the two parts.
            kSecAttrAccount as String: "\(login.origin)\n\(login.username)",
        ]
    }

    public func logins(for origin: String?) throws -> [SavedLogin] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        return items
            .compactMap { item -> SavedLogin? in
                guard let account = item[kSecAttrAccount as String] as? String,
                      let separator = account.firstIndex(of: "\n") else { return nil }
                return SavedLogin(
                    origin: String(account[..<separator]),
                    username: String(account[account.index(after: separator)...])
                )
            }
            .filter { origin == nil || $0.origin == origin }
            .sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
    }

    public func password(for login: SavedLogin) throws -> String? {
        var query = query(for: login)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ login: SavedLogin, password: String) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            query(for: login) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = query(for: login)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "KAFFIN: \(login.origin)"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete(_ login: SavedLogin) throws {
        let status = SecItemDelete(query(for: login) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func deleteAll() throws {
        for login in try logins(for: nil) {
            try delete(login)
        }
    }
}
