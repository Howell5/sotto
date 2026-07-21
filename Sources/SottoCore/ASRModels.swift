public enum ASRLanguage: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic = "auto"
    case chinese = "zh"
    case english = "en"
}

public struct ASRConfiguration: Equatable, Sendable {
    public var language: ASRLanguage
    public var sampleRate: Int
    public var maxSentenceSilenceMilliseconds: Int

    public init(
        language: ASRLanguage = .automatic,
        sampleRate: Int = 16_000,
        maxSentenceSilenceMilliseconds: Int = 1_300
    ) {
        self.language = language
        self.sampleRate = sampleRate
        self.maxSentenceSilenceMilliseconds = maxSentenceSilenceMilliseconds
    }
}

public enum ASRInputMode: Equatable, Sendable {
    case liveDuplex
    case bufferedFile
}

public enum ASRFailureKind: Equatable, Sendable {
    case unauthorized
    case badInput
    case insufficientBalance
    case rateLimited
    case contentFiltered
    case provider
    case transport
    case cancelled
}

public struct ASRFailure: Error, Equatable, Sendable {
    public let kind: ASRFailureKind
    public let providerCode: String?
    public let message: String
    public let retryable: Bool

    public init(
        kind: ASRFailureKind,
        providerCode: String? = nil,
        message: String,
        retryable: Bool
    ) {
        self.kind = kind
        self.providerCode = providerCode
        self.message = message
        self.retryable = retryable
    }
}

public enum ASREvent: Equatable, Sendable {
    case ready
    case hypothesis(fullText: String)
    case segmentFinal(fullText: String)
    case completed(fullText: String, billedSeconds: Double?)
    case failed(ASRFailure)
}
