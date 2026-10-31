import Darwin
import Foundation
import Observation

public enum OptimizationProfile: String, CaseIterable, Sendable {
    case standard
    case smartEfficiency
    case aggressiveSaving
}

public enum SleepTrigger: Sendable {
    case idle
    case memoryPressure
}

/// The one place that decides whether tabs may sleep on their own.
/// Standard answers no to both, so nothing automatic can run without the user choosing a profile.
@MainActor
@Observable
public final class PerformanceSettings {
    public var profile: OptimizationProfile {
        didSet { defaults.set(profile.rawValue, forKey: Key.profile) }
    }
    public var idleMinutes: Int {
        didSet { defaults.set(idleMinutes, forKey: Key.idleMinutes) }
    }
    public var protectsPinnedTabs: Bool {
        didSet { defaults.set(protectsPinnedTabs, forKey: Key.protectsPinned) }
    }
    public var excludedSites: [String] {
        didSet { defaults.set(excludedSites, forKey: Key.excludedSites) }
    }

    private enum Key {
        static let profile = "optimizationProfile"
        static let idleMinutes = "sleepIdleMinutes"
        static let protectsPinned = "sleepProtectsPinnedTabs"
        static let excludedSites = "sleepExcludedSites"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profile = defaults.string(forKey: Key.profile).flatMap(OptimizationProfile.init) ?? .standard
        idleMinutes = defaults.object(forKey: Key.idleMinutes) as? Int ?? 15
        protectsPinnedTabs = defaults.object(forKey: Key.protectsPinned) as? Bool ?? true
        excludedSites = defaults.stringArray(forKey: Key.excludedSites) ?? []
    }

    public var sleepsIdleTabs: Bool { profile == .aggressiveSaving }
    public var sleepsUnderMemoryPressure: Bool { profile != .standard }

    /// Accepts what people paste: addresses, capitals and `www.` all reduce to a site name.
    public static func sites(from text: String) -> [String] {
        text.split(separator: ",").compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty else { return nil }
            let address = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            return URL(string: address).flatMap(SiteMatch.siteHost)
        }
    }
}

public struct SleepCandidate: Sendable {
    let lastActiveAt: Date
    let isPinned: Bool
    let host: String?
    let hasMedia: Bool
    let isCapturing: Bool
    let hasActiveDownload: Bool
    let hasLoginPrompt: Bool

    public init(
        lastActiveAt: Date,
        isPinned: Bool,
        host: String?,
        hasMedia: Bool,
        isCapturing: Bool,
        hasActiveDownload: Bool,
        hasLoginPrompt: Bool
    ) {
        self.lastActiveAt = lastActiveAt
        self.isPinned = isPinned
        self.host = host
        self.hasMedia = hasMedia
        self.isCapturing = isCapturing
        self.hasActiveDownload = hasActiveDownload
        self.hasLoginPrompt = hasLoginPrompt
    }
}

public enum SleepPolicy {
    /// Protections always hold. Memory pressure only waives the idle wait.
    public static func allows(
        _ tab: SleepCandidate,
        idleMinutes: Int,
        protectsPinnedTabs: Bool,
        excludedSites: [String],
        requiringIdle: Bool,
        now: Date
    ) -> Bool {
        if tab.hasMedia || tab.isCapturing || tab.hasActiveDownload || tab.hasLoginPrompt { return false }
        if tab.isPinned, protectsPinnedTabs { return false }
        if let host = tab.host, excludedSites.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return false }
        return !requiringIdle || now.timeIntervalSince(tab.lastActiveAt) >= TimeInterval(idleMinutes * 60)
    }
}

public enum ProcessMemory {
    /// KAFFIN's own process, as Activity Monitor counts it. WebKit's page processes are not included.
    public static func footprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }
}
