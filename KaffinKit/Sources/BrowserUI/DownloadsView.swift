import BrowserCore
import SwiftUI

struct DownloadsView: View {
    let downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("downloads.title")).font(.headline)
            if downloads.items.isEmpty {
                Text(L10n.string("downloads.empty")).foregroundStyle(.secondary)
            }
            ForEach(downloads.items) { item in
                row(item)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func status(_ item: DownloadItem, speed: Int64) -> some View {
        Text(DownloadStatus.text(received: item.receivedBytes, total: item.totalBytes, bytesPerSecond: speed))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func retryButton(_ item: DownloadItem) -> some View {
        Button(L10n.string("downloads.retry")) { Task { await downloads.resume(item) } }.buttonStyle(.link)
    }

    private func row(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.fileName).lineLimit(1).truncationMode(.middle)
            switch item.state {
            case .downloading:
                HStack {
                    ProgressView(value: item.fraction)
                    Button(L10n.string("downloads.pause")) { Task { await downloads.pause(item) } }.buttonStyle(.link)
                    Button(L10n.string("downloads.cancel")) { downloads.cancel(item) }.buttonStyle(.link)
                }
                status(item, speed: item.bytesPerSecond)
            case .paused:
                status(item, speed: 0)
                HStack {
                    Text(L10n.string(item.canContinue ? "downloads.paused" : "downloads.pausedRestarts"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.string("downloads.resume")) { Task { await downloads.resume(item) } }.buttonStyle(.link)
                    Button(L10n.string("downloads.cancel")) { downloads.cancel(item) }.buttonStyle(.link)
                }
            case .finished:
                HStack {
                    Button(L10n.string("downloads.open")) { downloads.open(item) }.buttonStyle(.link)
                    Button(L10n.string("downloads.reveal")) { downloads.reveal(item) }.buttonStyle(.link)
                }
            case .cancelled:
                HStack {
                    Text(L10n.string("downloads.cancelled")).foregroundStyle(.secondary)
                    Spacer()
                    retryButton(item)
                }
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    retryButton(item)
                }
            }
        }
        .contextMenu {
            if item.state != .downloading {
                Button(L10n.string("downloads.remove")) { downloads.remove(item) }
            }
        }
    }
}
