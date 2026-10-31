import Foundation
import Observation

public struct AccentColor: Codable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

@MainActor
@Observable
public final class AccentSettings {
    /// Nil keeps the system accent color.
    public var color: AccentColor? {
        didSet { defaults.set(color.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.key) }
    }

    private static let key = "accentColor"
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        color = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AccentColor.self, from: $0) }
    }
}
