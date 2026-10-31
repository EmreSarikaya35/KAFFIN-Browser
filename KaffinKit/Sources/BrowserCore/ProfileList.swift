import Foundation
import Observation

public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
}

@MainActor
@Observable
public final class ProfileList {
    public private(set) var profiles: [Profile]

    private static let key = "profiles"
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        let hasDefault = stored.contains { $0.id == WebViewFactory.defaultProfileID }
        let fallback = Profile(id: WebViewFactory.defaultProfileID, name: L10n.string("profile.default"))
        profiles = hasDefault ? stored : [fallback] + stored
    }

    public func add(name: String) -> Profile? {
        guard let name = Self.clean(name) else { return nil }
        let profile = Profile(id: UUID(), name: name)
        profiles.append(profile)
        save()
        return profile
    }

    public func rename(_ id: UUID, to name: String) {
        guard let name = Self.clean(name), let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        save()
    }

    /// The default profile stays, so the browser always has somewhere to open.
    public func remove(_ id: UUID) -> Bool {
        guard id != WebViewFactory.defaultProfileID, profiles.contains(where: { $0.id == id }) else { return false }
        profiles.removeAll { $0.id == id }
        save()
        return true
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: Self.key)
    }

    private static func clean(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
