public enum OverlayDismissalReadinessDecision: Equatable, Sendable {
    case ready
    case waiting
    case unavailable
}

public enum OverlayDismissalReadinessPolicy {
    public static func resolve(
        expectedGeneration: Int,
        currentGeneration: Int,
        readyGeneration: Int?,
        isPanelVisible: Bool,
        hasTimedOut: Bool
    ) -> OverlayDismissalReadinessDecision {
        guard !hasTimedOut,
              expectedGeneration == currentGeneration
        else {
            return .unavailable
        }

        if readyGeneration == expectedGeneration, !isPanelVisible {
            return .ready
        }
        return .waiting
    }
}
