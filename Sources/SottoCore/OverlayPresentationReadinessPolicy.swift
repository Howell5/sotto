public enum OverlayPresentationReadinessDecision: Equatable, Sendable {
    case ready
    case waiting
    case unavailable
}

public enum OverlayPresentationReadinessPolicy {
    public static func resolve(
        expected: DictationOverlayPresentation,
        visible: DictationOverlayPresentation?,
        ready: DictationOverlayPresentation?,
        isPanelVisible: Bool,
        hasTimedOut: Bool
    ) -> OverlayPresentationReadinessDecision {
        guard !hasTimedOut,
              isPanelVisible,
              visible == expected
        else {
            return .unavailable
        }
        return ready == expected ? .ready : .waiting
    }
}
