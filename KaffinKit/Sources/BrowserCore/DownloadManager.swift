import AppKit
import CoreServices
import Foundation
import OSLog
import Observation
import WebKit

@MainActor
@Observable
public final class DownloadItem: Identifiable {
    public enum State: Equatable {
        case downloading
        case paused
        case finished
        case cancelled
        case failed(String)
    }

    public let id = UUID()
    public fileprivate(set) var fileName: String
    public fileprivate(set) var state = State.downloading
    public fileprivate(set) var fraction = 0.0
    public fileprivate(set) var receivedBytes: Int64 = 0
    /// Negative until the server states the size, and for servers that never do.
    public fileprivate(set) var totalBytes: Int64 = -1
    public fileprivate(set) var bytesPerSecond: Int64 = 0
    /// False once paused without resume data, because the file will then start over.
    public fileprivate(set) var canContinue = true
    public fileprivate(set) var destination: URL?

    @ObservationIgnored fileprivate var download: WKDownload
    @ObservationIgnored fileprivate let request: URLRequest?
    @ObservationIgnored fileprivate var resumeData: Data?
    /// Running from the moment Pause is pressed until WebKit hands over the resume data.
    @ObservationIgnored fileprivate var stopping: Task<Void, Never>?
    @ObservationIgnored fileprivate var rate = TransferRate()
    @ObservationIgnored fileprivate var lastUpdate = Date.distantPast
    @ObservationIgnored fileprivate var progress: NSKeyValueObservation?
    @ObservationIgnored fileprivate var stagedFile: URL?

    /// Progress fires per network chunk, so the visible numbers change only a few times a second.
    fileprivate func update(_ fraction: Double, received: Int64, total: Int64) {
        let now = Date.now
        rate.record(bytes: received, at: now)
        guard now.timeIntervalSince(lastUpdate) >= 0.25 else { return }
        lastUpdate = now
        self.fraction = fraction
        receivedBytes = received
        totalBytes = total
        bytesPerSecond = rate.bytesPerSecond
    }

    fileprivate init(download: WKDownload) {
        self.download = download
        request = download.originalRequest
        fileName = download.originalRequest?.url?.lastPathComponent ?? ""
    }
}

/// Lives above the tabs, and WKDownload outlives its WebView, so closing or sleeping a tab keeps a download running.
///
/// In the sandbox, WebKit's network process can write to the app's container but not to the user's Downloads folder,
/// and the download stalls without an error. Files are therefore staged in the container, then moved by the app,
/// which holds the Downloads entitlement.
@MainActor
@Observable
public final class DownloadManager: NSObject, WKDownloadDelegate {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "Downloads")

    public nonisolated static let stagingRoot = FileManager.default.temporaryDirectory.appending(path: "KAFFIN-Downloads")

    public private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let factory: WebViewFactory?
    /// Resuming needs a WebView of the same profile, and the original tab may be gone.
    @ObservationIgnored private lazy var resumingWebView = factory?.makeWebView()

    /// Without a directory, files go to the user's Downloads folder.
    public init(directory: URL? = nil, factory: WebViewFactory? = nil) {
        self.directory = directory
        self.factory = factory
    }

    private var folder: URL? {
        directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    public func hasActiveDownload(in webView: WKWebView) -> Bool {
        items.contains { $0.state == .downloading && $0.download.webView === webView }
    }

    public func attach(_ download: WKDownload) {
        let item = DownloadItem(download: download)
        items.insert(item, at: 0)
        follow(download, for: item)
    }

    private func follow(_ download: WKDownload, for item: DownloadItem) {
        download.delegate = self
        item.download = download
        item.rate = TransferRate()
        item.bytesPerSecond = 0
        item.progress = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                if let item, item.state == .downloading { item.update(fraction, received: received, total: total) }
            }
        }
    }

    public func cancel(_ item: DownloadItem) {
        guard item.state == .downloading || item.state == .paused else { return }
        let wasRunning = item.state == .downloading
        item.state = .cancelled
        item.progress = nil
        item.resumeData = nil
        guard wasRunning else {
            removeStagingFolder(of: item)
            return
        }
        item.download.cancel { [weak self] _ in
            Task { @MainActor in self?.removeStagingFolder(of: item) }
        }
    }

    /// WebKit has no real pause: the download stops, and keeps resume data if the server allows resuming.
    public func pause(_ item: DownloadItem) async {
        guard item.state == .downloading else { return }
        item.state = .paused
        item.progress = nil
        let download = item.download
        let stopping = Task {
            let resumeData = await withCheckedContinuation { continuation in
                download.cancel { continuation.resume(returning: $0) }
            }
            guard item.state == .paused else { return }
            item.resumeData = resumeData
            item.canContinue = resumeData != nil
        }
        item.stopping = stopping
        await stopping.value
    }

    /// Continues a paused download, or starts over when there is nothing to resume from.
    public func resume(_ item: DownloadItem) async {
        // A quick Resume must wait, or it finds no resume data yet and starts over.
        await item.stopping?.value
        item.stopping = nil
        guard item.state != .downloading, item.state != .finished,
              let webView = item.download.webView ?? resumingWebView else { return }
        item.state = .downloading
        item.canContinue = true
        if let resumeData = item.resumeData {
            item.resumeData = nil
            follow(await webView.resumeDownload(fromResumeData: resumeData), for: item)
        } else if let request = item.request {
            removeStagingFolder(of: item)
            item.fraction = 0
            follow(await webView.startDownload(using: request), for: item)
        }
    }

    public func remove(_ item: DownloadItem) {
        guard item.state != .downloading else { return }
        removeStagingFolder(of: item)
        items.removeAll { $0 === item }
    }

    public func reveal(_ item: DownloadItem) {
        if let destination = item.destination {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    public func open(_ item: DownloadItem) {
        if let destination = item.destination { NSWorkspace.shared.open(destination) }
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let staging = Self.stagingRoot.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            fail(item(for: download), error)
            return nil
        }
        let destination = DownloadRules.destination(for: suggestedFilename, in: staging)
        if let item = item(for: download) {
            item.fileName = destination.lastPathComponent
            item.stagedFile = destination
        }
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download), let staged = item.stagedFile, let folder else { return }
        item.progress = nil
        item.receivedBytes = download.progress.completedUnitCount
        item.totalBytes = download.progress.totalUnitCount
        item.bytesPerSecond = 0
        defer { removeStagingFolder(of: item) }
        do {
            try markQuarantined(staged, source: download.originalRequest?.url)
            let target = DownloadRules.destination(for: item.fileName, in: folder)
            try FileManager.default.moveItem(at: staged, to: target)
            item.destination = target
            item.fileName = target.lastPathComponent
            item.fraction = 1
            item.state = .finished
        } catch {
            fail(item, error)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.state == .downloading else { return }
        fail(item, error)
        // Kept when WebKit can resume, so Retry continues instead of starting over.
        item.resumeData = resumeData
        if resumeData == nil { removeStagingFolder(of: item) }
    }

    private func fail(_ item: DownloadItem?, _ error: Error) {
        Self.logger.error("Download failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        item?.state = .failed(error.localizedDescription)
        item?.progress = nil
    }

    /// Gatekeeper checks a downloaded app on first open only if this mark is present.
    private func markQuarantined(_ file: URL, source: URL?) throws {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "KAFFIN",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        properties[kLSQuarantineDataURLKey as String] = source
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        try file.setResourceValues(values)
    }

    private func removeStagingFolder(of item: DownloadItem) {
        if let staged = item.stagedFile {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        }
        item.stagedFile = nil
    }
}
