public enum DictationPhase: Equatable, Sendable {
    case idle
    case listening
    case processing
    case inserting
    case success
    case cancelled
    case error(message: String, recoveryText: String?)
}

public enum DictationEvent: Equatable, Sendable {
    case fnPressed
    case escapePressed
    case finishRequested
    case cancelRequested
    case noSpeechDetected
    case transcriptionSucceeded(String)
    case insertionSucceeded
    case operationFailed(message: String, recoveryText: String?)
    case resetRequested
}

public enum DictationEffect: Equatable, Sendable {
    case captureFocus
    case startRecording
    case stopRecordingAndTranscribe
    case cancelRecording
    case polishAndInsert(String)
    case copyToClipboard(String)
    case scheduleReset(afterMilliseconds: Int)
}

public struct DictationStateMachine: Sendable {
    public private(set) var phase: DictationPhase

    public init(phase: DictationPhase = .idle) {
        self.phase = phase
    }

    @discardableResult
    public mutating func handle(_ event: DictationEvent) -> [DictationEffect] {
        switch (phase, event) {
        case (.idle, .fnPressed):
            phase = .listening
            return [.captureFocus, .startRecording]
        case (.listening, .fnPressed), (.listening, .finishRequested):
            phase = .processing
            return [.stopRecordingAndTranscribe]
        case (.listening, .escapePressed), (.listening, .cancelRequested):
            phase = .cancelled
            return [.cancelRecording, .scheduleReset(afterMilliseconds: 500)]
        case (.processing, .noSpeechDetected):
            phase = .idle
            return []
        case let (.processing, .transcriptionSucceeded(text)):
            phase = .inserting
            return [.polishAndInsert(text)]
        case (.inserting, .insertionSucceeded):
            phase = .idle
            return []
        case let (_, .operationFailed(message, recoveryText)):
            phase = .error(message: message, recoveryText: recoveryText)
            if let recoveryText, !recoveryText.isEmpty {
                return [
                    .copyToClipboard(recoveryText),
                    .scheduleReset(afterMilliseconds: 4_000)
                ]
            }
            return [.scheduleReset(afterMilliseconds: 4_000)]
        case (_, .resetRequested):
            phase = .idle
            return []
        default:
            return []
        }
    }
}
