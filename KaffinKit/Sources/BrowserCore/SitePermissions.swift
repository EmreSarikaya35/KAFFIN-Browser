import Foundation
import Observation

public enum SitePermissionKind: String, CaseIterable, Sendable {
    case camera
    case microphone
    case location
}

public enum PermissionAnswer: Sendable {
    case allow
    case block
    case notNow
}

public struct SitePermission: Sendable, Equatable, Identifiable {
    public let site: String
    public let kind: SitePermissionKind
    public let isAllowed: Bool

    public var id: String { "\(kind.rawValue)|\(site)" }

    public init(site: String, kind: SitePermissionKind, isAllowed: Bool) {
        self.site = site
        self.kind = kind
        self.isAllowed = isAllowed
    }
}

public protocol SitePermissionStoring: Sendable {
    func sitePermission(_ kind: SitePermissionKind, site: String) async throws -> Bool?
    func setSitePermission(_ kind: SitePermissionKind, site: String, allowed: Bool) async throws
    func removeSitePermission(_ kind: SitePermissionKind, site: String) async throws
    func allSitePermissions() async throws -> [SitePermission]
}

@MainActor
@Observable
public final class SitePermissionsModel {
    public private(set) var entries: [SitePermission] = []
    @ObservationIgnored private let store: (any SitePermissionStoring)?

    public init(store: (any SitePermissionStoring)?) {
        self.store = store
    }

    public func reload() async {
        if let stored = try? await store?.allSitePermissions() { entries = stored }
    }

    public func set(_ entry: SitePermission, allowed: Bool) async {
        try? await store?.setSitePermission(entry.kind, site: entry.site, allowed: allowed)
        await reload()
    }

    public func remove(_ entry: SitePermission) async {
        try? await store?.removeSitePermission(entry.kind, site: entry.site)
        await reload()
    }
}
