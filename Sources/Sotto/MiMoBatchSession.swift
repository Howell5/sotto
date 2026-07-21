import Foundation
import SottoCore

actor MiMoBatchSession: ASRSession {
    nonisolated let inputMode: ASRInputMode = .bufferedFile

    private enum State: String, Sendable {
        case idle
        case recording
        case submitting
        case finished
        case cancelled
        case failed
    }

    private struct StreamMetadata: Decodable {
        struct Choice: Decodable {
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case finishReason = "finish_reason"
            }
        }

        struct Usage: Decodable {
            let seconds: Double?
        }

        struct ProviderError: Decodable {
            let code: String?
            let message: String?
        }

        let choices: [Choice]?
        let usage: Usage?
        let error: ProviderError?
    }

    private static let endpoint = URL(
        string: "https://api.xiaomimimo.com/v1/chat/completions"
    )!
    private static let maximumEncodedAudioBytes = 10_000_000
    private static let WAVHeaderBytes = 44
    private static let WAVDataURLPrefixBytes = "data:audio/wav;base64,".utf8.count

    private let apiKey: String
    private let urlSession: URLSession
    private let eventPipe = ASREventPipe()

    private var state: State = .idle
    private var configuration = ASRConfiguration()
    private var pcm = Data()
    private var submissionTask: Task<Void, Never>?
    private var submissionTimeoutTask: Task<Void, Never>?
    private var completionWaiters: [CheckedContinuation<Void, Error>] = []

    init(apiKey: String, urlSession: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlSession = urlSession
    }

    nonisolated func eventStream() -> AsyncThrowingStream<ASREvent, Error> {
        eventPipe.stream
    }

    func start(configuration: ASRConfiguration) async throws {
        guard state == .idle else {
            throw ASRSessionError.invalidState("MiMo 会话已经启动")
        }
        guard !apiKey.isEmpty else {
            throw ASRSessionError.invalidConfiguration("缺少 MiMo API Key")
        }
        guard configuration.sampleRate > 0 else {
            throw ASRSessionError.invalidConfiguration("采样率必须大于 0")
        }

        self.configuration = configuration
        pcm.removeAll(keepingCapacity: true)
        state = .recording
        eventPipe.continuation.yield(.ready)
    }

    func sendPCM16(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard state == .recording else {
            throw ASRSessionError.invalidState(
                "MiMo 当前状态 \(state.rawValue) 不能接收音频"
            )
        }

        let projectedPCMBytes = pcm.count + data.count
        let projectedWAVBytes = projectedPCMBytes + Self.WAVHeaderBytes
        let projectedBase64Bytes = 4 * ((projectedWAVBytes + 2) / 3)
        let projectedEncodedBytes = projectedBase64Bytes + Self.WAVDataURLPrefixBytes
        guard projectedEncodedBytes <= Self.maximumEncodedAudioBytes else {
            let error = ASRSessionError.audioTooLarge(
                maximumEncodedBytes: Self.maximumEncodedAudioBytes
            )
            let failure = ASRFailure(
                kind: .badInput,
                message: error.localizedDescription,
                retryable: false
            )
            fail(failure)
            throw failure
        }
        pcm.append(data)
    }

    func finish() async throws {
        switch state {
        case .recording:
            guard !pcm.isEmpty else {
                let failure = ASRFailure(
                    kind: .badInput,
                    message: ASRSessionError.emptyAudio.localizedDescription,
                    retryable: false
                )
                fail(failure)
                throw failure
            }
            state = .submitting
            let pcm = self.pcm
            let configuration = self.configuration
            submissionTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(120))
                } catch {
                    return
                }
                await self?.failIfStillSubmitting()
            }
            submissionTask = Task { [weak self] in
                await self?.submit(pcm: pcm, configuration: configuration)
            }

        case .submitting:
            break
        case .finished:
            return
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw ASRSessionError.invalidState("MiMo 会话已经失败")
        case .idle:
            throw ASRSessionError.invalidState("MiMo 会话尚未启动")
        }

        try await withCheckedThrowingContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    func cancel() async {
        guard state != .finished, state != .cancelled, state != .failed else {
            return
        }
        state = .cancelled
        submissionTimeoutTask?.cancel()
        submissionTimeoutTask = nil
        submissionTask?.cancel()
        submissionTask = nil
        pcm.removeAll(keepingCapacity: false)
        resumeCompletionWaiters(throwing: CancellationError())
        eventPipe.continuation.finish()
    }

    private func submit(pcm: Data, configuration: ASRConfiguration) async {
        do {
            let wav = try PCM16WAVEncoder().encode(
                pcm,
                sampleRate: configuration.sampleRate,
                channelCount: 1
            )
            let body = try MiMoASRWire.makeRequest(
                wav: wav,
                language: configuration.language,
                streamResponse: true
            )

            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = body

            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ASRSessionError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = try await responseMessage(
                    from: bytes,
                    statusCode: httpResponse.statusCode
                )
                throw MiMoASRWire.failure(
                    forHTTPStatus: httpResponse.statusCode,
                    message: message
                )
            }

            var fullText = ""
            var billedSeconds: Double?
            var sawTerminalChunk = false

            for try await line in bytes.lines {
                try Task.checkCancellation()
                let isDoneSentinel = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "data: [DONE]"
                if let metadata = decodeMetadata(fromSSELine: line) {
                    if let seconds = metadata.usage?.seconds {
                        billedSeconds = seconds
                    }
                    if let providerError = metadata.error {
                        throw ASRFailure(
                            kind: .provider,
                            providerCode: providerError.code,
                            message: providerError.message ?? "MiMo 请求失败",
                            retryable: false
                        )
                    }
                    if let finishReason = metadata.choices?.first?.finishReason {
                        switch finishReason {
                        case "stop":
                            sawTerminalChunk = true
                        case "content_filter":
                            throw ASRFailure(
                                kind: .contentFiltered,
                                providerCode: finishReason,
                                message: "MiMo 拒绝了这段音频的转写",
                                retryable: false
                            )
                        case "length":
                            throw ASRFailure(
                                kind: .provider,
                                providerCode: finishReason,
                                message: "MiMo 转写因输出长度上限而中止",
                                retryable: false
                            )
                        default:
                            throw ASRFailure(
                                kind: .provider,
                                providerCode: finishReason,
                                message: "MiMo 转写异常结束：\(finishReason)",
                                retryable: false
                            )
                        }
                    }
                }

                switch try MiMoASRWire.decodeSSELine(line) {
                case let .delta(delta):
                    fullText += delta
                    eventPipe.continuation.yield(.hypothesis(fullText: fullText))
                case .done:
                    if isDoneSentinel {
                        sawTerminalChunk = true
                    }
                case .ignored:
                    break
                }
                if isDoneSentinel { break }
            }

            guard sawTerminalChunk, !fullText.isEmpty else {
                throw ASRSessionError.invalidResponse
            }
            complete(fullText: fullText, billedSeconds: billedSeconds)
        } catch is CancellationError {
            guard state != .cancelled else { return }
            await cancel()
        } catch {
            guard state != .cancelled else { return }
            if let failure = error as? ASRFailure {
                fail(failure)
            } else if let sessionError = error as? ASRSessionError {
                fail(.init(
                    kind: .provider,
                    message: sessionError.localizedDescription,
                    retryable: false
                ))
            } else {
                fail(.transport(error))
            }
        }
    }

    private func responseMessage(
        from bytes: URLSession.AsyncBytes,
        statusCode: Int
    ) async throws -> String {
        var result = ""
        for try await line in bytes.lines {
            if result.utf8.count >= 4_096 { break }
            if !result.isEmpty { result.append("\n") }
            result.append(line)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "MiMo 请求失败（HTTP \(statusCode)）" : trimmed
    }

    private func decodeMetadata(fromSSELine line: String) -> StreamMetadata? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(StreamMetadata.self, from: data)
    }

    private func complete(fullText: String, billedSeconds: Double?) {
        guard state == .submitting else { return }
        state = .finished
        submissionTimeoutTask?.cancel()
        submissionTimeoutTask = nil
        pcm.removeAll(keepingCapacity: false)
        submissionTask = nil
        eventPipe.continuation.yield(
            .completed(fullText: fullText, billedSeconds: billedSeconds)
        )
        eventPipe.continuation.finish()
        resumeCompletionWaiters()
    }

    private func fail(_ failure: ASRFailure) {
        guard state != .failed, state != .finished, state != .cancelled else { return }
        state = .failed
        submissionTimeoutTask?.cancel()
        submissionTimeoutTask = nil
        submissionTask?.cancel()
        submissionTask = nil
        pcm.removeAll(keepingCapacity: false)
        eventPipe.continuation.yield(.failed(failure))
        eventPipe.continuation.finish()
        resumeCompletionWaiters(throwing: failure)
    }

    private func failIfStillSubmitting() {
        guard state == .submitting else { return }
        fail(.init(
            kind: .transport,
            providerCode: "submission-timeout",
            message: "MiMo 转写超时",
            retryable: true
        ))
    }

    private func resumeCompletionWaiters(throwing error: Error? = nil) {
        let waiters = completionWaiters
        completionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }
}
