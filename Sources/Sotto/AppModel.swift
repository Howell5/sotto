import AppKit
import Combine
import Foundation
import OSLog
import SottoCore

enum SpeechConnectionTestState: Equatable {
    case idle
    case testing
    case succeeded
    case failed(userMessage: String, diagnostic: String)
}

private enum BailianConnectionTestError: LocalizedError {
    case invalidCleanupRoute
    case cleanupRejected(TranscriptRejectionReason)
    case unexpectedCleanup(String)

    var errorDescription: String? {
        switch self {
        case .invalidCleanupRoute:
            "无法从当前 Workspace 和区域生成文字整理地址"
        case let .cleanupRejected(reason):
            "Qwen 返回了文字，但安全校验拒绝了结果：\(reason)"
        case let .unexpectedCleanup(text):
            "Qwen 改口验证结果不符合预期：\(text)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let logger = Logger(
        subsystem: "com.willhong.sotto",
        category: "dictation"
    )

    private struct CaptureRequest: Sendable {
        let provider: SpeechProviderKind
        let funRegion: FunRegion
        let funWorkspaceID: String
        let configuration: ASRConfiguration
        let credential: KeychainStore.Credential
    }

    @Published private(set) var phase: DictationPhase = .idle
    @Published var audioLevel: Double = 0
    @Published private(set) var lastResult: String?
    @Published private(set) var lastServiceError: String?
    @Published private(set) var statusDetail = "Ready"
    @Published private(set) var funKeyConfigured = false
    @Published private(set) var miMoKeyConfigured = false
    @Published private(set) var credentialSaveError: String?
    @Published private(set) var connectionTestState: SpeechConnectionTestState = .idle

    let settings: SettingsStore
    let permissions: PermissionCenter
    let keychain: KeychainStore

    private var stateMachine = DictationStateMachine()
    private weak var overlayController: OverlayPanelController?
    private weak var settingsWindowController: SettingsWindowController?
    private let microphone = MicrophoneCapture()
    private let audioTransport = AudioTransportRunner()
    private let textInsertion = TextInsertionService()
    private let transcriptGuard = TranscriptGuard()

    private var focusedTarget: FocusedTextTarget?
    private var activeSession: (any ASRSession)?
    private var activeSessionID: UUID?
    private var pcmContinuation: AsyncStream<Data>.Continuation?
    private var transportTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var connectionTestTask: Task<Void, Never>?
    private var connectionTestSession: (any ASRSession)?
    private var connectionTestID: UUID?
    private var activeSessionHasRecognizedContent = false
    private var cachedCredentials: [KeychainStore.Credential: String] = [:]
    private var loadedCredentials = Set<KeychainStore.Credential>()

    init(
        settings: SettingsStore = SettingsStore(),
        permissions: PermissionCenter = PermissionCenter(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.keychain = keychain
    }

    var providerSummary: String {
        settings.provider.title
    }

    var canStart: Bool {
        switch settings.provider {
        case .funASR:
            FunASRConfigurationPolicy.isReady(
                hasAPIKey: funKeyConfigured,
                workspaceInput: settings.funWorkspaceID
            )
        case .miMo: miMoKeyConfigured
        }
    }

    func attachOverlay(_ overlayController: OverlayPanelController) {
        self.overlayController = overlayController
        overlayController.render(phase: phase)
    }

    func attachSettingsWindow(_ controller: SettingsWindowController) {
        settingsWindowController = controller
    }

    func bootstrap() {
        permissions.refresh()
        Task { await refreshCredentialStatus() }
    }

    func shutdown() {
        invalidateConnectionTest()
        cancelActiveSession()
    }

    func toggleDictation() {
        if phase == .listening {
            finishDictation()
            return
        }
        guard phase == .idle else { return }

        permissions.refresh()
        guard canStart else {
            transitionToFailure(
                settings.provider == .funASR
                    ? "请先配置百炼 API Key 和 API Host"
                    : "请先配置语音服务 API Key"
            )
            return
        }
        guard permissions.microphone == .granted else {
            transitionToFailure("需要麦克风权限")
            return
        }

        invalidateConnectionTest()
        apply(.fnPressed)
    }

    func finishDictation() {
        guard phase == .listening else { return }
        apply(.finishRequested)
    }

    func cancelDictation() {
        guard phase == .listening else { return }
        apply(.cancelRequested)
    }

    func copyLastResult() {
        guard let lastResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastResult, forType: .string)
    }

    func openSettings() {
        settingsWindowController?.show()
    }

    func restoreSettingsAfterPermissionPrompt() {
        permissions.completeSettingsRestoration()
        permissions.refresh()
        settingsWindowController?.show()
    }

    @discardableResult
    func saveCredential(
        _ value: String,
        for credential: KeychainStore.Credential
    ) async -> Bool {
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try await keychain.remove(credential)
                cachedCredentials.removeValue(forKey: credential)
            } else {
                try await keychain.write(trimmed, for: credential)
                cachedCredentials[credential] = trimmed
            }
            loadedCredentials.insert(credential)
            await refreshCredentialStatus()
            credentialSaveError = nil
            invalidateConnectionTest()
            statusDetail = "Credential saved"
            return true
        } catch {
            let message = error.localizedDescription
            credentialSaveError = message
            statusDetail = message
            return false
        }
    }

    func refreshCredentialStatus() async {
        funKeyConfigured = await credentialValue(for: .funASR) != nil
        // The first release only exposes Bailian. Avoid touching a legacy MiMo
        // Keychain item during every launch when it cannot be selected in UI.
        miMoKeyConfigured = false
    }

    private func credentialValue(
        for credential: KeychainStore.Credential
    ) async -> String? {
        if loadedCredentials.contains(credential) {
            return cachedCredentials[credential]
        }

        let value = await keychain.read(credential)
        loadedCredentials.insert(credential)
        guard let value, !value.isEmpty else { return nil }
        cachedCredentials[credential] = value
        return value
    }

    func testSpeechConnection() {
        guard phase == .idle else {
            connectionTestState = .failed(
                userMessage: "请先结束当前听写",
                diagnostic: "connection-test-conflict · dictation is active"
            )
            return
        }
        guard settings.provider == .funASR else {
            connectionTestState = .failed(
                userMessage: "当前仅支持测试 Fun-ASR 实时连接",
                diagnostic: "connection-test-unsupported · MiMo requires an audio request"
            )
            return
        }
        guard funKeyConfigured else {
            connectionTestState = .failed(
                userMessage: "请先保存 API Key",
                diagnostic: "connection-test-configuration · missing saved API Key"
            )
            return
        }
        guard let workspaceID = BailianWorkspaceInput.normalizedID(
            from: settings.funWorkspaceID
        ) else {
            connectionTestState = .failed(
                userMessage: "请检查 API Host 或 Workspace ID",
                diagnostic: "connection-test-configuration · invalid Workspace ID"
            )
            return
        }
        guard connectionTestState != .testing else { return }

        let testID = UUID()
        let region = settings.funRegion
        connectionTestID = testID
        connectionTestState = .testing
        credentialSaveError = nil
        connectionTestTask = Task { [weak self] in
            await self?.runFunASRConnectionTest(
                testID: testID,
                region: region,
                workspaceID: workspaceID
            )
        }
    }

    func invalidateConnectionTest() {
        connectionTestID = nil
        connectionTestTask?.cancel()
        connectionTestTask = nil

        if let session = connectionTestSession {
            Task { await session.cancel() }
        }
        connectionTestSession = nil
        connectionTestState = .idle
    }

    private func runFunASRConnectionTest(
        testID: UUID,
        region: FunRegion,
        workspaceID: String
    ) async {
        guard let apiKey = await credentialValue(for: .funASR),
              !Task.isCancelled,
              connectionTestID == testID
        else {
            if !Task.isCancelled {
                finishConnectionTest(
                    testID: testID,
                    result: .failed(
                        userMessage: "无法读取已保存的 API Key",
                        diagnostic: "connection-test-keychain · credential unavailable"
                    )
                )
            }
            return
        }

        let session = FunASRRealtimeSession(
            apiKey: apiKey,
            workspaceID: workspaceID,
            region: region == .mainlandChina ? .mainlandChina : .singapore
        )
        guard connectionTestID == testID else { return }
        connectionTestSession = session
        let events = session.eventStream()

        do {
            try await session.start(
                configuration: ASRConfiguration(
                    language: .automatic,
                    sampleRate: 16_000,
                    maxSentenceSilenceMilliseconds: 1_300
                )
            )
            try await Self.waitUntilFunASRReady(events: events)
            try Task.checkCancellation()
            await session.cancel()
            try await verifyBailianCleanup(
                apiKey: apiKey,
                region: region,
                workspaceID: workspaceID
            )
            try Task.checkCancellation()
            guard currentConnectionConfigurationMatches(
                region: region,
                workspaceID: workspaceID
            ) else {
                invalidateConnectionTest()
                return
            }
            finishConnectionTest(testID: testID, result: .succeeded)
        } catch is CancellationError {
            await session.cancel()
            if connectionTestID == testID {
                invalidateConnectionTest()
            }
        } catch {
            await session.cancel()
            let result: SpeechConnectionTestState
            if let failure = error as? ASRFailure {
                result = .failed(
                    userMessage: ASRFailurePresenter.userMessage(
                        for: failure,
                        serviceName: "百炼"
                    ),
                    diagnostic: ASRFailurePresenter.diagnosticSummary(for: failure)
                )
            } else if error is TranscriptPolisherError
                        || error is BailianConnectionTestError {
                result = .failed(
                    userMessage: "文字整理模型验证失败",
                    diagnostic: error.localizedDescription
                )
            } else {
                result = .failed(
                    userMessage: "百炼双模型连接测试失败",
                    diagnostic: error.localizedDescription
                )
            }
            finishConnectionTest(testID: testID, result: result)
        }
    }

    private func currentConnectionConfigurationMatches(
        region: FunRegion,
        workspaceID: String
    ) -> Bool {
        settings.provider == .funASR
            && settings.funRegion == region
            && BailianWorkspaceInput.normalizedID(from: settings.funWorkspaceID) == workspaceID
    }

    private func verifyBailianCleanup(
        apiKey: String,
        region: FunRegion,
        workspaceID: String
    ) async throws {
        guard let route = BailianCleanupRoute.resolve(
            region: region == .mainlandChina ? .mainlandChina : .singapore,
            workspaceInput: workspaceID
        ) else {
            throw BailianConnectionTestError.invalidCleanupRoute
        }

        let rawText = "今晚6点吃饭，哦不，改成8点。"
        let polisher = TranscriptPolisher(route: route, apiKey: apiKey)
        let candidate = try await polisher.polish(rawText)
        switch transcriptGuard.evaluate(raw: rawText, polished: candidate) {
        case let .usePolished(text):
            guard text.contains("8"), !text.contains("6") else {
                throw BailianConnectionTestError.unexpectedCleanup(text)
            }
        case let .useOriginal(_, reason):
            throw BailianConnectionTestError.cleanupRejected(reason)
        }
    }

    private func finishConnectionTest(
        testID: UUID,
        result: SpeechConnectionTestState
    ) {
        guard connectionTestID == testID else { return }
        connectionTestID = nil
        connectionTestTask = nil
        connectionTestSession = nil
        connectionTestState = result
    }

    private nonisolated static func waitUntilFunASRReady(
        events: AsyncThrowingStream<ASREvent, Error>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }

            group.addTask {
                for try await event in events {
                    switch event {
                    case .ready:
                        return
                    case let .failed(failure):
                        throw failure
                    case .hypothesis, .segmentFinal, .completed:
                        continue
                    }
                }
                throw ASRFailure(
                    kind: .transport,
                    providerCode: "connection-test-ended",
                    message: "Fun-ASR 在返回 task-started 前关闭了连接",
                    retryable: true
                )
            }

            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ASRFailure(
                    kind: .transport,
                    providerCode: "connection-test-timeout",
                    message: "等待 Fun-ASR task-started 超时",
                    retryable: true
                )
            }

            guard try await group.next() != nil else {
                throw ASRFailure(
                    kind: .transport,
                    providerCode: "connection-test-empty",
                    message: "Fun-ASR 连接测试未返回结果",
                    retryable: true
                )
            }
        }
    }

    private func apply(_ event: DictationEvent) {
        let effects = stateMachine.handle(event)
        execute(effects)
        // Publish after synchronous effects: the listening capsule must never
        // appear before AVAudioEngine has installed its tap and started.
        publishState()
    }

    private func publishState() {
        phase = stateMachine.phase
        overlayController?.render(phase: phase)
    }

    private func execute(_ effects: [DictationEffect]) {
        for effect in effects {
            switch effect {
            case .captureFocus:
                focusedTarget = textInsertion.captureFocusedTarget()
                statusDetail = focusedTarget == nil
                    ? "No writable target; result will be copied"
                    : "Target captured"

            case .startRecording:
                statusDetail = "Listening"
                prepareCaptureAndConnect()

            case .stopRecordingAndTranscribe:
                statusDetail = "Thinking"
                stopCaptureAndFinishStream()

            case .cancelRecording:
                cancelActiveSession()
                focusedTarget = nil
                statusDetail = "Cancelled"

            case let .polishTranscript(text):
                Task { [weak self] in
                    await self?.polishTranscript(text)
                }

            case let .insertText(text):
                Task { [weak self] in
                    await self?.insertText(text)
                }

            case let .copyToClipboard(text):
                lastResult = text
                copyLastResult()

            case let .scheduleReset(afterMilliseconds):
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(afterMilliseconds))
                    guard let self, !Task.isCancelled else { return }
                    self.apply(.resetRequested)
                }
            }
        }
    }

    private func prepareCaptureAndConnect() {
        let provider = settings.provider
        let request = CaptureRequest(
            provider: provider,
            funRegion: settings.funRegion,
            funWorkspaceID: settings.funWorkspaceID,
            configuration: ASRConfiguration(
                language: ASRLanguage(rawValue: settings.languageRawValue) ?? .automatic,
                sampleRate: 16_000,
                maxSentenceSilenceMilliseconds: 1_300
            ),
            credential: provider == .funASR ? .funASR : .miMo
        )
        let sessionID = UUID()
        activeSessionID = sessionID
        activeSessionHasRecognizedContent = false
        let pipe = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        pcmContinuation = pipe.continuation

        do {
            try microphone.start(
                onPCM: { data in
                    pipe.continuation.yield(data)
                },
                onLevel: { [weak self] level in
                    Task { @MainActor [weak self] in
                        guard self?.phase == .listening else { return }
                        self?.audioLevel = level
                    }
                },
                onError: { [weak self] error in
                    let message = error.localizedDescription
                    Task { @MainActor [weak self] in
                        self?.transitionToFailure(message, sessionID: sessionID)
                    }
                }
            )
        } catch {
            transitionToFailure(error.localizedDescription, sessionID: sessionID)
            return
        }

        let recordingLimitSeconds = provider == .miMo ? 180 : 300
        recordingLimitTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(recordingLimitSeconds))
            } catch {
                return
            }
            guard let self,
                  self.activeSessionID == sessionID,
                  self.phase == .listening
            else { return }
            self.statusDetail = provider == .miMo
                ? "MiMo 录音已达 3 分钟，正在转写"
                : "录音已达 5 分钟，正在完成转写"
            self.apply(.fnPressed)
        }

        transportTask = Task { [weak self] in
            await self?.runRecognitionPipeline(
                request: request,
                stream: pipe.stream,
                sessionID: sessionID
            )
        }
    }

    private func runRecognitionPipeline(
        request: CaptureRequest,
        stream: AsyncStream<Data>,
        sessionID: UUID
    ) async {
        guard let apiKey = await credentialValue(for: request.credential),
              !Task.isCancelled,
              activeSessionID == sessionID
        else {
            if activeSessionID == sessionID {
                transitionToFailure("请先配置语音服务 API Key", sessionID: sessionID)
            }
            return
        }

        let session: any ASRSession
        switch request.provider {
        case .funASR:
            session = FunASRRealtimeSession(
                apiKey: apiKey,
                workspaceID: request.funWorkspaceID,
                region: request.funRegion == .mainlandChina
                    ? .mainlandChina
                    : .singapore
            )
        case .miMo:
            session = MiMoBatchSession(apiKey: apiKey)
        }
        activeSession = session

        eventTask = Task { [weak self] in
            do {
                for try await event in session.eventStream() {
                    guard !Task.isCancelled else { return }
                    self?.receive(event, from: sessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.receiveTransportError(error, from: sessionID)
            }
        }

        do {
            try await audioTransport.run(
                session: session,
                configuration: request.configuration,
                stream: stream
            )
        } catch is CancellationError {
            return
        } catch {
            receiveTransportError(error, from: sessionID)
        }
    }

    private func stopCaptureAndFinishStream() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        audioLevel = 0
        let capturedPCM = microphone.stop()
        if EmptyDictationPolicy.isTriviallyShortPCM16(
            byteCount: capturedPCM.count,
            sampleRate: 16_000
        ) {
            discardNoSpeech()
            return
        }
        pcmContinuation?.finish()
        pcmContinuation = nil
    }

    private func receive(_ event: ASREvent, from sessionID: UUID) {
        guard activeSessionID == sessionID else { return }

        switch event {
        case .ready:
            statusDetail = phase == .listening ? "Listening · connected" : "Finishing audio"

        case let .hypothesis(fullText), let .segmentFinal(fullText):
            if !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                activeSessionHasRecognizedContent = true
            }
            // Live words stay out of the overlay for privacy and distraction control.
            break

        case let .completed(fullText, _):
            let transcript = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                completeSession(sessionID)
                discardNoSpeech()
                return
            }
            completeSession(sessionID)
            lastServiceError = nil
            apply(.transcriptionSucceeded(transcript))

        case let .failed(failure):
            handleASRFailure(failure, sessionID: sessionID)
        }
    }

    private func receiveTransportError(_ error: Error, from sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        if let failure = error as? ASRFailure {
            handleASRFailure(failure, sessionID: sessionID)
        } else {
            transitionToFailure("无法连接语音服务", sessionID: sessionID)
        }
    }

    private func handleASRFailure(_ failure: ASRFailure, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        if EmptyDictationPolicy.shouldSilentlyDiscard(
            failureKind: failure.kind,
            hasRecognizedContent: activeSessionHasRecognizedContent
        ) {
            Self.logger.info(
                "Discarding empty dictation after provider code=\(failure.providerCode ?? "none", privacy: .public)"
            )
            discardNoSpeech()
            return
        }
        transitionToFailure(failure, sessionID: sessionID)
    }

    private func discardNoSpeech() {
        cancelActiveSession()
        focusedTarget = nil
        lastServiceError = nil
        statusDetail = "Ready"
        apply(.noSpeechDetected)
    }

    private func polishTranscript(_ rawText: String) async {
        var finalText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.cleanupEnabled,
           let route = BailianCleanupRoute.resolve(
               region: settings.funRegion == .mainlandChina
                   ? .mainlandChina
                   : .singapore,
               workspaceInput: settings.funWorkspaceID
           ),
           let apiKey = await credentialValue(for: .funASR) {
            do {
                let polisher = TranscriptPolisher(route: route, apiKey: apiKey)
                let candidate = try await polisher.polish(rawText)
                switch transcriptGuard.evaluate(raw: rawText, polished: candidate) {
                case let .usePolished(text):
                    finalText = text
                case let .useOriginal(text, reason):
                    finalText = text
                    statusDetail = "Cleanup rejected (\(String(describing: reason))); using transcript"
                }
            } catch {
                Self.logger.error(
                    "Cleanup failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                statusDetail = "Cleanup unavailable; using transcript"
            }
        }

        apply(.transcriptPolished(finalText))
    }

    private func insertText(_ finalText: String) async {
        if let overlayController {
            let isOverlayDismissed =
                await overlayController.waitUntilDismissedForInsertion()
            guard phase == .inserting else { return }
            guard isOverlayDismissed else {
                let message = ClipboardRecoveryCopy.message(
                    reason: "无法关闭听写状态"
                )
                lastResult = finalText
                focusedTarget = nil
                statusDetail = message
                apply(
                    .operationFailed(
                        message: message,
                        recoveryText: finalText
                    )
                )
                return
            }
        }
        guard phase == .inserting else { return }

        lastResult = finalText
        let target = focusedTarget
        focusedTarget = nil
        let outcome = await textInsertion.insert(finalText, into: target)

        switch outcome {
        case .inserted:
            statusDetail = "Ready"
            apply(.insertionSucceeded)
        case let .copied(message):
            statusDetail = message
            apply(.operationFailed(message: message, recoveryText: finalText))
        }
    }

    private func transitionToFailure(
        _ message: String,
        recoveryText: String? = nil,
        sessionID: UUID? = nil
    ) {
        if let sessionID, activeSessionID != sessionID { return }
        if case .error = phase { return }

        cancelActiveSession()
        focusedTarget = nil
        audioLevel = 0
        statusDetail = message
        apply(.operationFailed(message: message, recoveryText: recoveryText))
    }

    private func transitionToFailure(_ failure: ASRFailure, sessionID: UUID) {
        let diagnostic = ASRFailurePresenter.diagnosticSummary(for: failure)
        lastServiceError = diagnostic
        Self.logger.error(
            "ASR failed: code=\(failure.providerCode ?? "none", privacy: .public) detail=\(diagnostic, privacy: .private(mask: .hash))"
        )
        transitionToFailure(message(for: failure), sessionID: sessionID)
    }

    private func completeSession(_ sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        activeSession = nil
        activeSessionHasRecognizedContent = false
        pcmContinuation = nil
        transportTask = nil
        eventTask = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        audioLevel = 0
    }

    private func cancelActiveSession() {
        let session = activeSession
        activeSessionID = nil
        activeSession = nil
        activeSessionHasRecognizedContent = false

        _ = microphone.stop()
        pcmContinuation?.finish()
        pcmContinuation = nil
        transportTask?.cancel()
        transportTask = nil
        eventTask?.cancel()
        eventTask = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        audioLevel = 0

        if let session {
            Task {
                await session.cancel()
            }
        }
    }

    private func message(for failure: ASRFailure) -> String {
        switch failure.kind {
        case .unauthorized:
            ASRFailurePresenter.userMessage(
                for: failure,
                serviceName: settings.provider == .funASR ? "百炼" : "MiMo"
            )
        case .badInput:
            failure.message.contains("音频") || failure.message.contains("录到")
                ? "没听到清晰语音"
                : "语音格式不受支持"
        case .insufficientBalance:
            "语音服务余额不足"
        case .rateLimited:
            "请求过于频繁，请稍后再试"
        case .contentFiltered:
            "语音服务拒绝了这段内容"
        case .provider:
            "语音服务暂时不可用"
        case .transport:
            "无法连接语音服务"
        case .cancelled:
            "已取消"
        }
    }
}
