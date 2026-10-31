import BrowserCore
import Foundation
import Testing

struct BookmarkFileTests {
    private let chromeExport = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://swift.org/" ADD_DATE="2" ICON="data:image/png;base64,AAAA">Swift &amp; Friends</A>
            <DT><H3 ADD_DATE="3">İş</H3>
            <DL><p>
                <DT><A HREF="https://example.com/a?x=1&amp;y=2">Örnek</A>
            </DL><p>
        </DL><p>
        <DT><A HREF="https://outside.example/">Other</A>
        <DT><H3>Other Folder</H3>
        <DL><p>
            <DT><A HREF="https://other.example/">Inside</A>
        </DL><p>
    </DL><p>
    """

    @Test func parsesChromeExportWithBarAtRoot() {
        let tree = BookmarkFile.parse(chromeExport)

        #expect(tree.items.map(\.title) == ["Swift & Friends", "Other"])
        #expect(tree.folders.map(\.title) == ["İş", "Other Folder"])
        #expect(tree.folders[0].items == [
            BookmarkItem(url: URL(string: "https://example.com/a?x=1&y=2")!, title: "Örnek"),
        ])
    }

    @Test func dropsScriptAndLocalAddresses() {
        let tree = BookmarkFile.parse("""
        <DL><DT><A HREF="javascript:alert(1)">Bad</A>
        <DT><A HREF="file:///etc/passwd">Local</A>
        <DT><A HREF="data:text/html,x">Data</A>
        <DT><A HREF="https://good.example/">Good</A></DL>
        """)
        #expect(tree.items.map(\.title) == ["Good"])
    }

    @Test func untitledBookmarkUsesItsHost() {
        let tree = BookmarkFile.parse(#"<DL><DT><A HREF="https://good.example/"></A></DL>"#)
        #expect(tree.items.first?.title == "good.example")
    }

    @Test func decodesNumericEntities() {
        let tree = BookmarkFile.parse(#"<DL><DT><A HREF="https://a.example/">It&#39;s &#x41;</A></DL>"#)
        #expect(tree.items.first?.title == "It's A")
    }

    @Test func tooDeepNestingCannotExhaustStack() {
        let open = String(repeating: "<DT><H3>F</H3><DL>", count: 5000)
        let close = String(repeating: "</DL>", count: 5000)
        let tree = BookmarkFile.parse("<DL>\(open)<DT><A HREF=\"https://deep.example/\">Deep</A>\(close)</DL>")

        var depth = 0
        var level = tree
        while let next = level.folders.first {
            level = next
            depth += 1
        }
        #expect(depth <= BookmarkFile.maximumDepth)
        #expect(level.items.map(\.title) == ["Deep"], "Bookmarks past the limit stay in the deepest folder")
    }

    @Test func unbalancedFileDoesNotCrash() {
        #expect(BookmarkFile.parse("</DL></DL><DT><A HREF=\"https://a.example/\">A</A>").items.count == 1)
        #expect(BookmarkFile.parse("").items.isEmpty)
        #expect(BookmarkFile.parse("<A HREF=\"https://a.example/\">").items.isEmpty)
    }

    @Test func exportReadsBackIdentically() {
        let tree = BookmarkTree(
            items: [BookmarkItem(url: URL(string: "https://a.example/?x=1&y=2")!, title: "A & \"B\" <C>")],
            folders: [
                BookmarkTree(id: 1, title: "İç", items: [BookmarkItem(url: URL(string: "https://b.example/")!, title: "B")]),
            ]
        )
        let again = BookmarkFile.parse(BookmarkFile.export(tree))

        #expect(again.items == tree.items)
        #expect(again.folders.map(\.title) == ["İç"])
        #expect(again.folders[0].items == tree.folders[0].items)
    }

    @Test func exportCannotInjectMarkupThroughTitles() {
        let tree = BookmarkTree(items: [
            BookmarkItem(url: URL(string: "https://a.example/")!, title: "</A><script>alert(1)</script>"),
        ])
        #expect(!BookmarkFile.export(tree).contains("<script>"))
    }
}

struct BookmarkBarFitTests {
    @Test func keepsWhatFitsAndLeavesRoomForOverflowButton() {
        #expect(BookmarkBarFit.visibleCount(widths: [100, 100, 100], available: 500, overflowWidth: 30) == 3)
        #expect(BookmarkBarFit.visibleCount(widths: [100, 100, 100], available: 280, overflowWidth: 30) == 2)
        #expect(BookmarkBarFit.visibleCount(widths: [100, 100, 100], available: 300, overflowWidth: 30) == 3)
        #expect(BookmarkBarFit.visibleCount(widths: [200], available: 100, overflowWidth: 30) == 0)
        #expect(BookmarkBarFit.visibleCount(widths: [], available: 100, overflowWidth: 30) == 0)
    }
}
