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

    private func row(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.fileName).lineLimit(1).truncationMode(.middle)
            switch item.state {
            case .downloading:
                HStack {
                    ProgressView(value: item.fraction)
                    Button(L10n.string("downloads.cancel")) { downloads.cancel(item) }.buttonStyle(.link)
                }
            case .finished:
                HStack {
                    Button(L10n.string("downloads.open")) { downloads.open(item) }.buttonStyle(.link)
                    Button(L10n.string("downloads.reveal")) { downloads.reveal(item) }.buttonStyle(.link)
                }
            case .cancelled:
                Text(L10n.string("downloads.cancelled")).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .contextMenu {
            if item.state != .downloading {
                Button(L10n.string("downloads.remove")) { downloads.remove(item) }
            }
        }
    }
}
