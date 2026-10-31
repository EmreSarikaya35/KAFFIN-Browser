import Foundation

/// Average speed over the last few seconds, so the number follows the connection without jumping on every chunk.
public struct TransferRate: Sendable {
    private static let window: TimeInterval = 4
    private var samples: [(bytes: Int64, date: Date)] = []

    public init() {}

    public mutating func record(bytes: Int64, at date: Date) {
        samples.append((bytes, date))
        samples.removeAll { date.timeIntervalSince($0.date) > Self.window }
    }

    public var bytesPerSecond: Int64 {
        guard let first = samples.first, let last = samples.last else { return 0 }
        let seconds = last.date.timeIntervalSince(first.date)
        return seconds > 0 ? Int64(Double(last.bytes - first.bytes) / seconds) : 0
    }
}

public enum DownloadStatus {
    /// A negative total means the server did not say how large the file is.
    public static func text(received: Int64, total: Int64, bytesPerSecond: Int64, locale: Locale = .current) -> String {
        let size = { (bytes: Int64) in bytes.formatted(.byteCount(style: .file).locale(locale)) }
        var parts = [total > 0 ? "\(size(received)) / \(size(total))" : size(received)]
        if bytesPerSecond > 0 {
            parts.append(String(format: L10n.string("downloads.speed"), size(bytesPerSecond)))
            if total > received {
                parts.append(timeLeft(seconds: (total - received) / bytesPerSecond))
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func timeLeft(seconds: Int64) -> String {
        if seconds < 60 { return String(format: L10n.string("downloads.secondsLeft"), seconds + 1) }
        return String(format: L10n.string("downloads.minutesLeft"), (seconds + 59) / 60)
    }
}
