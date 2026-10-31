import BrowserCore
import Foundation
import Testing

struct DownloadRulesTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "kaffin-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func keepsFreeFilename() throws {
        let directory = try makeDirectory()
        #expect(DownloadRules.destination(for: "report.pdf", in: directory).lastPathComponent == "report.pdf")
    }

    @Test func numbersDuplicatesBeforeExtension() throws {
        let directory = try makeDirectory()
        FileManager.default.createFile(atPath: directory.appending(path: "report.pdf").path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: directory.appending(path: "report (1).pdf").path(percentEncoded: false), contents: nil)
        #expect(DownloadRules.destination(for: "report.pdf", in: directory).lastPathComponent == "report (2).pdf")
    }

    @Test func numbersDuplicatesWithoutExtension() throws {
        let directory = try makeDirectory()
        FileManager.default.createFile(atPath: directory.appending(path: "notes").path(percentEncoded: false), contents: nil)
        #expect(DownloadRules.destination(for: "notes", in: directory).lastPathComponent == "notes (1)")
    }

    @Test(arguments: ["../../evil.command", "/etc/passwd", "a/b/c.txt"])
    func serverCannotChooseFolder(name: String) throws {
        let directory = try makeDirectory()
        let result = DownloadRules.destination(for: name, in: directory)
        #expect(result.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    }

    @Test(arguments: ["", ".", "..", "/"])
    func unusableNamesGetFallback(name: String) throws {
        let directory = try makeDirectory()
        #expect(DownloadRules.destination(for: name, in: directory).lastPathComponent == "download")
    }

    @Test func downloadsWhatCannotBeShown() {
        #expect(DownloadRules.shouldDownload(canShowMIMEType: false, contentDisposition: nil))
    }

    @Test func showsDisplayableContent() {
        #expect(!DownloadRules.shouldDownload(canShowMIMEType: true, contentDisposition: nil))
        #expect(!DownloadRules.shouldDownload(canShowMIMEType: true, contentDisposition: "inline"))
    }

    @Test func honorsAttachmentHeaderInAnyCase() {
        #expect(DownloadRules.shouldDownload(canShowMIMEType: true, contentDisposition: "Attachment; filename=a.pdf"))
    }
}

struct ErrorPageTests {
    @Test func escapesPageControlledText() {
        let html = ErrorPage.html(host: "<script>alert(1)</script>", message: "a & \"b\"")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("a &amp; &quot;b&quot;"))
    }

    @Test(arguments: [NSURLErrorCancelled])
    func cancelledNavigationShowsNoPage(code: Int) {
        #expect(!ErrorPage.shouldShow(for: NSError(domain: NSURLErrorDomain, code: code)))
    }

    @Test func webKitDownloadInterruptionShowsNoPage() {
        #expect(!ErrorPage.shouldShow(for: NSError(domain: "WebKitErrorDomain", code: 102)))
    }

    @Test func connectionFailureShowsPage() {
        #expect(ErrorPage.shouldShow(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
    }
}
