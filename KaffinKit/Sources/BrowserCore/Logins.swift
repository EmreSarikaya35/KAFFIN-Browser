import Foundation
import Observation

public struct SavedLogin: Sendable, Hashable, Identifiable {
    public let origin: String
    public let username: String

    public var id: Self { self }

    public init(origin: String, username: String) {
        self.origin = origin
        self.username = username
    }
}

public protocol CredentialStoring: Sendable {
    /// Without an origin, returns every login of the profile.
    func logins(for origin: String?) async throws -> [SavedLogin]
    func password(for login: SavedLogin) async throws -> String?
    func save(_ login: SavedLogin, password: String) async throws
    func delete(_ login: SavedLogin) async throws
}

public enum LoginPrompt: Sendable, Equatable {
    case save(SavedLogin, password: String, isUpdate: Bool)
    case fill([SavedLogin])
}

public enum LoginOrigin {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1"]

    /// Logins match the exact origin, so a subdomain never receives another site's password.
    /// Plain http is refused, apart from loopback, because the password would cross the network unencrypted.
    public static func make(from url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

@MainActor
@Observable
public final class PasswordsModel {
    public private(set) var logins: [SavedLogin] = []
    @ObservationIgnored private let store: (any CredentialStoring)?

    public init(store: (any CredentialStoring)?) {
        self.store = store
    }

    public func reload() async {
        if let stored = try? await store?.logins(for: nil) { logins = stored }
    }

    public func delete(_ login: SavedLogin) async {
        try? await store?.delete(login)
        await reload()
    }

    public func password(for login: SavedLogin) async -> String? {
        try? await store?.password(for: login)
    }
}
