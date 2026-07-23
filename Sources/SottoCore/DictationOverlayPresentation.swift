public enum DictationOverlayPresentation: Equatable, Sendable {
    case listening
    case thinking
    case cancelled
    case error

    public static func resolve(
        _ phase: DictationPhase
    ) -> DictationOverlayPresentation? {
        switch phase {
        case .idle, .success:
            nil
        case .listening:
            .listening
        case .processing, .inserting:
            .thinking
        case .cancelled:
            .cancelled
        case .error:
            .error
        }
    }
}
