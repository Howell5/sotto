public enum DictationOverlayPresentation: Equatable, Sendable {
    case listening
    case thinking
    case writing
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
        case .processing, .polishing:
            .thinking
        case .inserting:
            .writing
        case .cancelled:
            .cancelled
        case .error:
            .error
        }
    }
}
