import BrowserCore
import Foundation

/// Runs only for profiles that sleep tabs. In Standard there is no timer and no memory listener at all.
@MainActor
final class TabSleepScheduler {
    private static let checkInterval = Duration.seconds(60)

    private let settings: PerformanceSettings
    private let sleepTabs: @MainActor (SleepTrigger) async -> Void
    private var idleTask: Task<Void, Never>?
    private var memorySource: DispatchSourceMemoryPressure?

    init(settings: PerformanceSettings, sleepTabs: @escaping @MainActor (SleepTrigger) async -> Void) {
        self.settings = settings
        self.sleepTabs = sleepTabs
    }

    func start() {
        let (sleepsIdle, watchesMemory) = withObservationTracking {
            (settings.sleepsIdleTabs, settings.sleepsUnderMemoryPressure)
        } onChange: { [weak self] in
            Task { @MainActor in self?.start() }
        }
        idleTask?.cancel()
        idleTask = sleepsIdle ? makeIdleTask() : nil
        memorySource?.cancel()
        memorySource = watchesMemory ? makeMemorySource() : nil
    }

    private func makeIdleTask() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard !Task.isCancelled else { return }
                await self?.sleepTabs(.idle)
            }
        }
    }

    private func makeMemorySource() -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.sleepTabs(.memoryPressure) }
        }
        source.resume()
        return source
    }
}
