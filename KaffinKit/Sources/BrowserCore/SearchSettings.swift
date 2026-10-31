import Foundation
import Observation

extension SearchEngine {
    public static let bing = SearchEngine(name: "Bing", queryTemplate: "https://www.bing.com/search?q=%s")
    public static let duckDuckGo = SearchEngine(name: "DuckDuckGo", queryTemplate: "https://duckduckgo.com/?q=%s")
    public static let brave = SearchEngine(name: "Brave Search", queryTemplate: "https://search.brave.com/search?q=%s")
    public static let builtIn = [google, bing, duckDuckGo, brave]
}

@MainActor
@Observable
public final class SearchSettings {
    public private(set) var engine: SearchEngine

    private static let nameKey = "searchEngineName"
    private static let customKey = "searchEngineCustomTemplate"
    public static let customName = "Custom"

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let name = defaults.string(forKey: Self.nameKey)
        if name == Self.customName, let template = defaults.string(forKey: Self.customKey), Self.isValid(template) {
            engine = SearchEngine(name: Self.customName, queryTemplate: template)
        } else {
            engine = SearchEngine.builtIn.first { $0.name == name } ?? .google
        }
    }

    public func select(_ engine: SearchEngine) {
        self.engine = engine
        defaults.set(engine.name, forKey: Self.nameKey)
    }

    /// Returns false and changes nothing when the template is not usable.
    public func setCustom(template: String) -> Bool {
        guard Self.isValid(template) else { return false }
        defaults.set(template, forKey: Self.customKey)
        select(SearchEngine(name: Self.customName, queryTemplate: template))
        return true
    }

    private static func isValid(_ template: String) -> Bool {
        guard template.contains("%s"), let components = URLComponents(string: template) else { return false }
        return components.scheme == "https" && components.host?.isEmpty == false
    }
}
