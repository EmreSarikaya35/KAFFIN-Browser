import AppKit
import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class DownloadItem: Identifiable {
    public enum State: Equatable {
        case downloading
        case finished
        case cancelled
        case failed(String)
    }

    public let id = UUID()
    public fileprivate(set) var fileName: String
    public fileprivate(set) var state = State.downloading
    public fileprivate(set) var fraction = 0.0
    public fileprivate(set) var destination: URL?

    @ObservationIgnored fileprivate let download: WKDownload
    @ObservationIgnored fileprivate var progress: NSKeyValueObservation?

    fileprivate init(download: WKDownload) {
        self.download = download
        fileName = download.originalRequest?.url?.lastPathComponent ?? ""
    }
}

/// Lives above the tabs, and WKDownload outlives its WebView, so closing or sleeping a tab keeps a download running.
// shortcut: no pause, resume or retry yet; WebKit only offers cancel with resume data. Add with the Downloads page.
@MainActor
@Observable
public final class DownloadManager: NSObject, WKDownloadDelegate {
    public private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let directory: URL?

    /// Without a directory, files go to the user's Downloads folder.
    public init(directory: URL? = nil) {
        self.directory = directory
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    public func attach(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(download: download)
        items.insert(item, at: 0)
        item.progress = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                // Progress fires per network chunk; a whole-percent step is enough for the UI.
                if let item, fraction - item.fraction >= 0.01 { item.fraction = fraction }
            }
        }
    }

    public func cancel(_ item: DownloadItem) {
        guard item.state == .downloading else { return }
        item.download.cancel { _ in }
        item.state = .cancelled
    }

    public func remove(_ item: DownloadItem) {
        if item.state != .downloading { items.removeAll { $0 === item } }
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
        let folder = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let folder else { return nil }
        let destination = DownloadRules.destination(for: suggestedFilename, in: folder)
        if let item = item(for: download) {
            item.destination = destination
            item.fileName = destination.lastPathComponent
        }
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.fraction = 1
        item.state = .finished
        item.progress = nil
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.state != .cancelled else { return }
        item.state = .failed(error.localizedDescription)
        item.progress = nil
    }
}
