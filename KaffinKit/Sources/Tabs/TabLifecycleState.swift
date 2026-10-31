public enum TabLifecycleState: Sendable, Equatable {
    case active
    case background
    case sleeping
    case restoring
    case failed

    public func canTransition(to next: TabLifecycleState) -> Bool {
        switch (self, next) {
        case (.active, .background), (.active, .failed),
             (.background, .active), (.background, .sleeping), (.background, .failed),
             (.sleeping, .restoring),
             (.restoring, .active), (.restoring, .background), (.restoring, .failed),
             (.failed, .restoring), (.failed, .background):
            true
        default:
            false
        }
    }
}
