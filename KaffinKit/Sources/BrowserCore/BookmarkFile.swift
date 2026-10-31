import Foundation

public struct BookmarkTree: Sendable, Equatable, Identifiable {
    /// Nil for the root, and for folders that are not stored yet.
    public let id: Int64?
    public let title: String
    public let items: [BookmarkItem]
    public let folders: [BookmarkTree]

    public init(id: Int64? = nil, title: String = "", items: [BookmarkItem] = [], folders: [BookmarkTree] = []) {
        self.id = id
        self.title = title
        self.items = items
        self.folders = folders
    }
}

public struct BookmarkImportResult: Sendable, Equatable {
    public let added: Int
    public let skipped: Int

    public init(added: Int, skipped: Int) {
        self.added = added
        self.skipped = skipped
    }
}

/// The Netscape bookmark HTML that Chrome, Safari and Firefox all read and write.
public enum BookmarkFile {
    public static let maximumDepth = 32

    private static let tag = try! NSRegularExpression(pattern: #"<(/?)(dl|h3|a)(?=[\s>])([^>]*)>"#, options: .caseInsensitive)
    private static let href = try! NSRegularExpression(pattern: #"\bhref\s*=\s*"([^"]*)""#, options: .caseInsensitive)
    private static let numericEntity = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-f]+);"#, options: .caseInsensitive)

    private final class Node {
        let title: String
        var items: [BookmarkItem] = []
        var folders: [Node] = []

        init(title: String = "") {
            self.title = title
        }

        var tree: BookmarkTree {
            BookmarkTree(title: title, items: items, folders: folders.map(\.tree))
        }
    }

    /// The file is outside data: only web addresses survive, and nesting depth is capped.
    public static func parse(_ html: String) -> BookmarkTree {
        let text = html as NSString
        let root = Node()
        var levels = [root]
        var pending: (title: String, isToolbar: Bool)?

        for match in tag.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let isClosing = match.range(at: 1).length > 0
            let name = text.substring(with: match.range(at: 2)).lowercased()
            let attributes = text.substring(with: match.range(at: 3))

            switch (name, isClosing) {
            case ("dl", false):
                levels.append(enter(pending, from: levels))
                pending = nil
            case ("dl", true):
                if levels.count > 1 { levels.removeLast() }
            case ("h3", false):
                guard let title = innerText(after: match, in: text) else { continue }
                pending = (decode(title), attributes.uppercased().contains("PERSONAL_TOOLBAR_FOLDER"))
            case ("a", false):
                guard let title = innerText(after: match, in: text), let url = webAddress(in: attributes) else { continue }
                let decoded = decode(title).trimmingCharacters(in: .whitespacesAndNewlines)
                levels[levels.count - 1].items.append(
                    BookmarkItem(url: url, title: decoded.isEmpty ? url.host() ?? url.absoluteString : decoded)
                )
            default:
                break
            }
        }
        return root.tree
    }

    /// Every `<DL>` adds a level so `</DL>` stays balanced, but past the limit the level repeats the deepest folder.
    private static func enter(_ pending: (title: String, isToolbar: Bool)?, from levels: [Node]) -> Node {
        guard let pending else { return levels[levels.count - 1] }
        if pending.isToolbar { return levels[0] }
        let parent = levels[levels.count - 1]
        if distinctDepth(of: levels) >= maximumDepth { return parent }
        let folder = Node(title: pending.title)
        parent.folders.append(folder)
        return folder
    }

    private static func distinctDepth(of levels: [Node]) -> Int {
        zip(levels, levels.dropFirst()).filter { $0 !== $1 }.count
    }

    private static func innerText(after match: NSTextCheckingResult, in text: NSString) -> String? {
        let start = match.range.upperBound
        let rest = NSRange(location: start, length: text.length - start)
        let end = text.range(of: "<", range: rest)
        return end.location == NSNotFound ? nil : text.substring(with: NSRange(location: start, length: end.location - start))
    }

    private static func webAddress(in attributes: String) -> URL? {
        let text = attributes as NSString
        guard let match = href.firstMatch(in: attributes, range: NSRange(location: 0, length: text.length)),
              let url = URL(string: decode(text.substring(with: match.range(at: 1)))),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func decode(_ text: String) -> String {
        var result = text as NSString
        for match in numericEntity.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let isHex = match.range(at: 1).length > 0
            let digits = (text as NSString).substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                result = result.replacingCharacters(in: match.range, with: String(scalar)) as NSString
            }
        }
        return (result as String)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    public static func export(_ tree: BookmarkTree) -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            #"<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">"#,
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
            #"<DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>"#,
        ]
        append(tree, to: &lines)
        lines.append("</DL><p>")
        return lines.joined(separator: "\n")
    }

    private static func append(_ tree: BookmarkTree, to lines: inout [String]) {
        lines.append("<DL><p>")
        for folder in tree.folders {
            lines.append("<DT><H3>\(escape(folder.title))</H3>")
            append(folder, to: &lines)
        }
        for item in tree.items {
            lines.append(#"<DT><A HREF="\#(escape(item.url.absoluteString))">\#(escape(item.title))</A>"#)
        }
        lines.append("</DL><p>")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum BookmarkBarFit {
    /// How many entries fit, keeping room for the overflow button whenever some must hide.
    public static func visibleCount(widths: [CGFloat], available: CGFloat, overflowWidth: CGFloat) -> Int {
        if widths.reduce(0, +) <= available { return widths.count }
        var used: CGFloat = 0
        return widths.prefix {
            used += $0
            return used <= available - overflowWidth
        }.count
    }
}
