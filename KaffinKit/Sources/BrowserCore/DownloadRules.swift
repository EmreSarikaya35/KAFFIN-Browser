import Foundation

public enum DownloadRules {
    /// The name comes from the server, so only its last component is used.
    public static func destination(for suggestedName: String, in directory: URL) -> URL {
        var name = URL(fileURLWithPath: suggestedName, relativeTo: URL(fileURLWithPath: "/")).lastPathComponent
        if name.isEmpty || name == "/" || name == "." || name == ".." { name = "download" }

        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var number = 1
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let numbered = "\(stem) (\(number))"
            candidate = directory.appending(path: suffix.isEmpty ? numbered : "\(numbered).\(suffix)")
            number += 1
        }
        return candidate
    }

    private static let webPageTypes: Set<String> = ["text/html", "application/xhtml+xml"]

    /// WebKit can report a real page as not showable, so web pages follow only the server's explicit request.
    public static func shouldDownload(mimeType: String?, canShowMIMEType: Bool, contentDisposition: String?) -> Bool {
        if contentDisposition?.lowercased().hasPrefix("attachment") == true { return true }
        if let mimeType, webPageTypes.contains(mimeType.lowercased()) { return false }
        return !canShowMIMEType
    }
}
