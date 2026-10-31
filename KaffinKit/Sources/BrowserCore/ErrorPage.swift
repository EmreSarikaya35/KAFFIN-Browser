import Foundation

/// Static page for failed navigations. It has no script, and every inserted value is escaped.
public enum ErrorPage {
    private static let webKitErrorDomain = "WebKitErrorDomain"
    // WebKitErrorFrameLoadInterruptedByPolicyChange, reported when a navigation becomes a download.
    private static let frameLoadInterrupted = 102

    public static func shouldShow(for error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return false }
        return !(error.domain == webKitErrorDomain && error.code == frameLoadInterrupted)
    }

    public static func html(host: String, message: String) -> String {
        """
        <!doctype html>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(host))</title>
        <style>
        body { font: 15px -apple-system, sans-serif; max-width: 520px; margin: 18vh auto; padding: 0 24px; }
        h1 { font-size: 24px; font-weight: 600; }
        </style>
        <h1>\(escape(L10n.string("error.title")))</h1>
        <p>\(escape(host))</p>
        <p>\(escape(message))</p>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
