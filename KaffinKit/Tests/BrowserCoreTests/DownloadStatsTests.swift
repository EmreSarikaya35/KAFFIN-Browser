import BrowserCore
import Foundation
import Testing

struct TransferRateTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func measuresBytesOverElapsedTime() {
        var rate = TransferRate()
        rate.record(bytes: 0, at: start)
        rate.record(bytes: 1_000_000, at: start.addingTimeInterval(1))
        rate.record(bytes: 3_000_000, at: start.addingTimeInterval(2))
        #expect(rate.bytesPerSecond == 1_500_000)
    }

    @Test func forgetsOldSamples() {
        var rate = TransferRate()
        rate.record(bytes: 0, at: start)
        rate.record(bytes: 10_000_000, at: start.addingTimeInterval(1))
        rate.record(bytes: 10_000_000, at: start.addingTimeInterval(9))
        rate.record(bytes: 11_000_000, at: start.addingTimeInterval(10))
        #expect(rate.bytesPerSecond == 1_000_000)
    }

    @Test func oneSampleHasNoSpeedYet() {
        var rate = TransferRate()
        rate.record(bytes: 500, at: start)
        #expect(rate.bytesPerSecond == 0)
    }
}

struct DownloadStatusTests {
    private let english = Locale(identifier: "en_US")

    @Test func showsAmountSpeedAndTimeLeft() {
        let text = DownloadStatus.text(
            received: 12_300_000, total: 45_000_000, bytesPerSecond: 2_100_000, locale: english
        )
        #expect(text == "12.3 MB / 45 MB · 2.1 MB/s · 16 s left")
    }

    @Test func unknownSizeShowsOnlyWhatIsKnown() {
        let text = DownloadStatus.text(received: 12_300_000, total: -1, bytesPerSecond: 2_100_000, locale: english)
        #expect(text == "12.3 MB · 2.1 MB/s")
    }

    @Test func noSpeedYetLeavesItOut() {
        let text = DownloadStatus.text(received: 1_000_000, total: 2_000_000, bytesPerSecond: 0, locale: english)
        #expect(text == "1 MB / 2 MB")
    }

    @Test(arguments: [
        (Int64(3_600), "1 h left"),
        (Int64(30_000), "8 h 20 min left"),
        (Int64(90_000), "1 d 1 h left"),
        (Int64(172_800), "2 d left"),
    ])
    func longWaitsReadInHoursAndDays(seconds: Int64, expected: String) {
        let text = DownloadStatus.text(
            received: 0,
            total: seconds * 1_000_000,
            bytesPerSecond: 1_000_000,
            locale: english
        )
        #expect(text.hasSuffix("· \(expected)"), "\(text)")
    }

    @Test func longWaitsReadInMinutes() {
        let text = DownloadStatus.text(received: 0, total: 600_000_000, bytesPerSecond: 1_000_000, locale: english)
        #expect(text == "Zero kB / 600 MB · 1 MB/s · 10 min left")
    }
}
