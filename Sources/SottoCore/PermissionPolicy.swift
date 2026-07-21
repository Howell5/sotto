public enum AppPermissionKind: Equatable, Hashable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
}

public enum AppPermissionState: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case restricted
    case misconfigured
}

public enum AppPermissionAction: Equatable, Sendable {
    case none
    case request
    case openSystemSettings
    case unavailable
}

public struct PermissionPolicy: Sendable {
    public init() {}

    public static func action(
        for kind: AppPermissionKind,
        state: AppPermissionState
    ) -> AppPermissionAction {
        switch state {
        case .granted:
            .none
        case .notDetermined:
            .request
        case .denied:
            .openSystemSettings
        case .restricted, .misconfigured:
            .unavailable
        }
    }

    public static func unresolvedSystemState(
        requestAttempted: Bool
    ) -> AppPermissionState {
        requestAttempted ? .denied : .notDetermined
    }

    public static func canMonitorFn(
        accessibility: AppPermissionState,
        inputMonitoring: AppPermissionState
    ) -> Bool {
        accessibility == .granted || inputMonitoring == .granted
    }
}
