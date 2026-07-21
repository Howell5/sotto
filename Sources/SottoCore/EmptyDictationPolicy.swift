public enum EmptyDictationPolicy {
    public static func shouldSilentlyDiscard(
        failureKind: ASRFailureKind,
        hasRecognizedContent: Bool
    ) -> Bool {
        failureKind == .badInput && !hasRecognizedContent
    }

    public static func isTriviallyShortPCM16(
        byteCount: Int,
        sampleRate: Int
    ) -> Bool {
        guard sampleRate > 0 else { return true }
        let oneHundredMilliseconds = sampleRate * 2 / 10
        return byteCount < oneHundredMilliseconds
    }
}
