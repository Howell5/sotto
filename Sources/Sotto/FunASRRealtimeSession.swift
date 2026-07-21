import Foundation
import SottoCore

actor FunASRRealtimeSession: ASRSession {
    enum Region: Sendable {
        case mainlandChina
        case singapore

        fileprivate var serviceRegion: FunASRServiceRegion {
            switch self {
            case .mainlandChina:
                .mainlandChina
            case .singapore:
                .singapore
            }
        }
    }

    nonisolated let inputMode: ASRInputMode = .liveDuplex

    private enum State: String, Sendable {
        case idle
        case starting
        case active
        case finishing
        case finished
        case cancelled
        case failed
    }

    private let apiKey: String
    private let workspaceID: String
    private let region: Region
    private let urlSession: URLSession
    private let eventPipe = ASREventPipe()

    private var state: State = .idle
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var taskID = ""
    private var chunker = PCMChunker(frameByteCount: 3_200)
    private var pendingFrames: [Data] = []
    private var isDrainingFrames = false
    private var finishRequested = false
    private var finishCommandSent = false
    private var assembler = FunTranscriptAssembler()
    private var completionWaiters: [CheckedContinuation<Void, Error>] = []

    init(
        apiKey: String,
        workspaceID: String,
        region: Region,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        self.urlSession = urlSession
    }

    nonisolated func eventStream() -> AsyncThrowingStream<ASREvent, Error> {
        eventPipe.stream
    }

    func start(configuration: ASRConfiguration) async throws {
        guard state == .idle else {
            throw ASRSessionError.invalidState("Fun-ASR 会话已经启动")
        }
        guard !apiKey.isEmpty else {
            throw ASRSessionError.invalidConfiguration("缺少 Fun-ASR API Key")
        }
        guard configuration.sampleRate > 0 else {
            throw ASRSessionError.invalidConfiguration("采样率必须大于 0")
        }

        let bytesPerFrame = max(1, configuration.sampleRate * 2 / 10)
        chunker = PCMChunker(frameByteCount: bytesPerFrame)
        taskID = UUID().uuidString.lowercased()
        assembler = FunTranscriptAssembler()
        state = .starting

        do {
            let route = try makeConnectionRoute()
            var request = URLRequest(url: route.endpoint)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(
                route.workspaceHeaderValue,
                forHTTPHeaderField: "X-DashScope-WorkSpace"
            )
            request.setValue("Sotto/1.0", forHTTPHeaderField: "User-Agent")

            let socket = urlSession.webSocketTask(with: request)
            self.socket = socket
            socket.resume()

            let runTask = try makeRunTask(configuration: configuration)
            guard let runTaskJSON = String(data: runTask, encoding: .utf8) else {
                throw ASRSessionError.invalidResponse
            }

            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            startTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await self?.failIfStillStarting()
            }
            try await socket.send(.string(runTaskJSON))
        } catch {
            let failure = failure(for: error)
            fail(failure)
            throw failure
        }
    }

    func sendPCM16(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        guard state == .starting || state == .active else {
            throw ASRSessionError.invalidState(
                "Fun-ASR 当前状态 \(state.rawValue) 不能接收音频"
            )
        }
        guard !finishRequested else {
            throw ASRSessionError.invalidState("Fun-ASR 已经开始结束当前会话")
        }

        pendingFrames.append(contentsOf: chunker.append(data))
        startFrameDrainIfNeeded()
    }

    func finish() async throws {
        switch state {
        case .starting, .active, .finishing:
            break
        case .finished:
            return
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw ASRSessionError.invalidState("Fun-ASR 会话已经失败")
        case .idle:
            throw ASRSessionError.invalidState("Fun-ASR 会话尚未启动")
        }

        if !finishRequested {
            let remainder = chunker.drain()
            if !remainder.isEmpty {
                pendingFrames.append(remainder)
            }
            finishRequested = true
            finishTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await self?.failIfFinishDeadlineExpires()
            }
            startFrameDrainIfNeeded()
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
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pendingFrames.removeAll(keepingCapacity: false)
        resumeCompletionWaiters(throwing: CancellationError())
        eventPipe.continuation.finish()
    }

    private func makeConnectionRoute() throws -> FunASRConnectionRoute {
        guard let route = FunASRConnectionRoute.resolve(
            region: region.serviceRegion,
            workspaceInput: workspaceID
        ) else {
            throw ASRSessionError.invalidEndpoint
        }
        return route
    }

    private func receiveLoop() async {
        guard let socket else { return }

        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .string(value):
                    data = Data(value.utf8)
                case let .data(value):
                    data = value
                @unknown default:
                    continue
                }

                let event = try FunASRWire.decodeServerEvent(data)
                handle(event)
                if state == .finished || state == .failed || state == .cancelled {
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard state != .cancelled, state != .finished, state != .failed else {
                return
            }
            fail(failure(for: error))
        }
    }

    private func handle(_ event: FunServerEvent) {
        switch event {
        case .started:
            guard state == .starting else { return }
            startTimeoutTask?.cancel()
            startTimeoutTask = nil
            state = .active
            eventPipe.continuation.yield(.ready)
            startFrameDrainIfNeeded()

        case let .transcript(_, _, isFinal, _):
            let fullText = assembler.apply(event)
            if isFinal {
                eventPipe.continuation.yield(.segmentFinal(fullText: fullText))
            } else {
                eventPipe.continuation.yield(.hypothesis(fullText: fullText))
            }

        case .heartbeat, .unknown:
            break

        case .finished:
            guard state == .finishing || finishRequested else { return }
            let fullText = assembler.apply(event)
            state = .finished
            startTimeoutTask?.cancel()
            startTimeoutTask = nil
            finishTimeoutTask?.cancel()
            finishTimeoutTask = nil
            eventPipe.continuation.yield(
                .completed(
                    fullText: fullText,
                    billedSeconds: assembler.billedSeconds
                )
            )
            eventPipe.continuation.finish()
            resumeCompletionWaiters()
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            receiveTask = nil

        case let .failed(code, message):
            fail(FunASRFailureMapper.providerFailure(code: code, message: message))
        }
    }

    private func startFrameDrainIfNeeded() {
        guard state == .active, !isDrainingFrames else { return }
        guard !pendingFrames.isEmpty || finishRequested else { return }

        isDrainingFrames = true
        Task { [weak self] in
            await self?.drainFramesAndFinishIfNeeded()
        }
    }

    private func makeRunTask(configuration: ASRConfiguration) throws -> Data {
        let data = try FunASRWire.makeRunTask(
            taskID: taskID,
            configuration: configuration
        )
        guard configuration.language != .automatic else { return data }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var payload = root["payload"] as? [String: Any],
              var parameters = payload["parameters"] as? [String: Any]
        else {
            throw ASRSessionError.invalidResponse
        }
        parameters["language_hints"] = [configuration.language.rawValue]
        payload["parameters"] = parameters
        root["payload"] = payload
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func failIfStillStarting() {
        guard state == .starting else { return }
        fail(.init(
            kind: .transport,
            providerCode: "task-start-timeout",
            message: "Fun-ASR 启动超时",
            retryable: true
        ))
    }

    private func drainFramesAndFinishIfNeeded() async {
        defer {
            isDrainingFrames = false
            if state == .active, !pendingFrames.isEmpty || finishRequested {
                startFrameDrainIfNeeded()
            }
        }

        guard let socket else {
            fail(.init(
                kind: .transport,
                message: "Fun-ASR WebSocket 不可用",
                retryable: true
            ))
            return
        }

        do {
            while state == .active, !pendingFrames.isEmpty {
                let frame = pendingFrames.removeFirst()
                try await socket.send(.data(frame))
            }

            if state == .active,
               finishRequested,
               pendingFrames.isEmpty,
               !finishCommandSent {
                let finishTask = try FunASRWire.makeFinishTask(taskID: taskID)
                guard let finishTaskJSON = String(data: finishTask, encoding: .utf8) else {
                    throw ASRSessionError.invalidResponse
                }
                finishCommandSent = true
                state = .finishing
                try await socket.send(.string(finishTaskJSON))
            }
        } catch {
            fail(failure(for: error))
        }
    }

    private func failure(for error: Error) -> ASRFailure {
        if let failure = error as? ASRFailure {
            return failure
        }
        if let sessionError = error as? ASRSessionError {
            return .init(
                kind: .badInput,
                message: sessionError.localizedDescription,
                retryable: false
            )
        }

        if let statusCode = (socket?.response as? HTTPURLResponse)?.statusCode {
            switch statusCode {
            case 401, 403:
                return .init(
                    kind: .unauthorized,
                    providerCode: String(statusCode),
                    message: "Fun-ASR 鉴权失败（HTTP \(statusCode)）",
                    retryable: false
                )
            case 429:
                return .init(
                    kind: .rateLimited,
                    providerCode: String(statusCode),
                    message: "Fun-ASR 请求过于频繁",
                    retryable: true
                )
            case 500...599:
                return .init(
                    kind: .provider,
                    providerCode: String(statusCode),
                    message: "Fun-ASR 服务暂时不可用（HTTP \(statusCode)）",
                    retryable: true
                )
            default:
                break
            }
        }
        return .transport(error)
    }

    private func failIfFinishDeadlineExpires() {
        guard finishRequested,
              state == .starting || state == .active || state == .finishing
        else { return }
        fail(.init(
            kind: .transport,
            providerCode: "task-finish-timeout",
            message: "Fun-ASR 完成转写超时",
            retryable: true
        ))
    }

    private func fail(_ failure: ASRFailure) {
        guard state != .failed, state != .finished, state != .cancelled else { return }
        state = .failed
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pendingFrames.removeAll(keepingCapacity: false)
        eventPipe.continuation.yield(.failed(failure))
        eventPipe.continuation.finish()
        resumeCompletionWaiters(throwing: failure)
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
