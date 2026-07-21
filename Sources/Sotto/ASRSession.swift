import Foundation
import SottoCore

protocol ASRSession: Actor {
    nonisolated var inputMode: ASRInputMode { get }

    nonisolated func eventStream() -> AsyncThrowingStream<ASREvent, Error>
    func start(configuration: ASRConfiguration) async throws
    func sendPCM16(_ data: Data) async throws
    func finish() async throws
    func cancel() async
}

enum ASRSessionError: LocalizedError, Equatable, Sendable {
    case invalidState(String)
    case invalidConfiguration(String)
    case invalidEndpoint
    case emptyAudio
    case audioTooLarge(maximumEncodedBytes: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .invalidState(message):
            message
        case let .invalidConfiguration(message):
            message
        case .invalidEndpoint:
            "无法创建语音服务地址"
        case .emptyAudio:
            "没有录到可识别的音频"
        case let .audioTooLarge(maximumEncodedBytes):
            "音频超过服务上限（Base64 最多 \(maximumEncodedBytes) 字节）"
        case .invalidResponse:
            "语音服务返回了无法解析的响应"
        }
    }
}

final class ASREventPipe: Sendable {
    let stream: AsyncThrowingStream<ASREvent, Error>
    let continuation: AsyncThrowingStream<ASREvent, Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<ASREvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        stream = pair.stream
        continuation = pair.continuation
    }
}

extension ASRFailure {
    static func transport(_ error: Error, retryable: Bool = true) -> ASRFailure {
        ASRFailure(
            kind: .transport,
            providerCode: nil,
            message: error.localizedDescription,
            retryable: retryable
        )
    }
}
