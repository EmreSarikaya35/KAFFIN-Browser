import Foundation

public enum L10n {
    public static func string(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }
}
