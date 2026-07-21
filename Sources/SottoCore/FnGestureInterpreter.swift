public enum FnGestureEvent: Equatable, Sendable {
    case fnChanged(isDown: Bool, hasOtherModifiers: Bool)
    case nonModifierKeyPressed
    case activationDeadlineReached
}

public enum FnGestureAction: Equatable, Sendable {
    case none
    case scheduleActivation(afterMilliseconds: Int)
    case cancelPendingActivation
    case activateToggle
}

public struct FnGestureInterpreter: Sendable {
    private enum State: Sendable {
        case idle
        case arming
        case activatedUntilRelease
        case suppressedUntilRelease
    }

    private var state: State = .idle

    public init() {}

    public mutating func handle(_ event: FnGestureEvent) -> FnGestureAction {
        switch (state, event) {
        case (.idle, .fnChanged(isDown: true, hasOtherModifiers: false)):
            state = .arming
            return .scheduleActivation(afterMilliseconds: 120)

        case (.idle, .fnChanged(isDown: true, hasOtherModifiers: true)):
            state = .suppressedUntilRelease
            return .none

        case (.arming, .fnChanged(isDown: false, hasOtherModifiers: _)):
            state = .idle
            return .activateToggle

        case (.arming, .activationDeadlineReached):
            state = .activatedUntilRelease
            return .activateToggle

        case (.arming, .nonModifierKeyPressed):
            state = .suppressedUntilRelease
            return .cancelPendingActivation

        case (.activatedUntilRelease, .fnChanged(isDown: false, hasOtherModifiers: _)),
             (.suppressedUntilRelease, .fnChanged(isDown: false, hasOtherModifiers: _)):
            state = .idle
            return .none

        default:
            return .none
        }
    }
}
