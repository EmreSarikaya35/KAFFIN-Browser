import BrowserCore
import Credentials
import Foundation
import Testing

/// Uses the real Keychain under a throwaway profile.
struct KeychainCredentialStoreTests {
    /// Cleanup is awaited, so no test item outlives the test process.
    private func cleaningUp(_ stores: KeychainCredentialStore..., body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            for store in stores { try? await store.deleteAll() }
            throw error
        }
        for store in stores { try await store.deleteAll() }
    }

    @Test func savesUpdatesFindsAndDeletes() async throws {
        let store = KeychainCredentialStore(profileID: UUID())
        let login = SavedLogin(origin: "https://example.com", username: "ada")
        try await cleaningUp(store) {
            try await store.save(login, password: "first")
            try await store.save(login, password: "second")

            #expect(try await store.logins(for: "https://example.com") == [login])
            #expect(try await store.logins(for: "https://other.example") == [])
            #expect(try await store.password(for: login) == "second")

            try await store.delete(login)
            #expect(try await store.password(for: login) == nil)
        }
    }

    @Test func profilesCannotSeeEachOthersLogins() async throws {
        let first = KeychainCredentialStore(profileID: UUID())
        let second = KeychainCredentialStore(profileID: UUID())
        let login = SavedLogin(origin: "https://example.com", username: "ada")
        try await cleaningUp(first, second) {
            try await first.save(login, password: "secret")
            #expect(try await second.logins(for: nil).isEmpty)
            #expect(try await second.password(for: login) == nil)
        }
    }

    @Test func listsAllLoginsSortedAndKeepsUnusualNames() async throws {
        let store = KeychainCredentialStore(profileID: UUID())
        let logins = [
            SavedLogin(origin: "https://a.example", username: "name with space@x.y"),
            SavedLogin(origin: "https://b.example", username: ""),
        ]
        try await cleaningUp(store) {
            for login in logins { try await store.save(login, password: "p") }
            #expect(try await store.logins(for: nil) == logins)
        }
    }
}
