import AppKit
import BrowserCore
import CoreLocation

/// macOS decides location for the whole app, on top of the per-site choice.
/// WebKit never asks by itself, so without this the system question would not appear.
@MainActor
final class SystemLocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var reading: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    private static func isGranted(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways
    }

    func requestAccess() async -> Bool {
        guard manager.authorizationStatus == .notDetermined else {
            return Self.isGranted(manager.authorizationStatus)
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
        }
    }

    func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            reading.append(continuation)
            if reading.count == 1 { manager.requestLocation() }
        }
    }

    private func finishReading(_ location: CLLocation?) {
        let continuations = reading
        reading = []
        continuations.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in finishReading(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finishReading(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            let continuations = waiting
            waiting = []
            continuations.forEach { $0.resume(returning: Self.isGranted(status)) }
        }
    }
}
