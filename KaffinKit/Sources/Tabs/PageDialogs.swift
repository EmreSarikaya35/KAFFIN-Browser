import Foundation

/// What a page may ask the user. Without a presenter, every answer is the safe one: no.
@MainActor
public protocol PageDialogPresenting: AnyObject {
    func alert(_ message: String, from site: String) async
    func confirm(_ message: String, from site: String) async -> Bool
    func prompt(_ message: String, defaultText: String?, from site: String) async -> String?
    func credential(for site: String, realm: String?) async -> URLCredential?
    func confirmOpening(_ url: URL, from site: String) async -> Bool
}
