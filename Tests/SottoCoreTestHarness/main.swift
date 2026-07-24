import Darwin
import Foundation
import SottoCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect<T: Equatable>(
    _ actual: T,
    equals expected: T,
    _ message: String
) throws {
    guard actual == expected else {
        throw TestFailure(
            description: "\(message): expected \(expected), got \(actual)"
        )
    }
}

private func testFnPressFromIdleBeginsListeningAndRequestsRecording() throws {
    var machine = DictationStateMachine()

    let effects = machine.handle(.fnPressed)

    try expect(machine.phase, equals: .listening, "phase after Fn press")
    try expect(
        effects,
        equals: [.captureFocus, .startRecording],
        "effects after Fn press"
    )
}

private func testFnPressWhileListeningStopsRecordingAndBeginsProcessing() throws {
    var machine = DictationStateMachine(phase: .listening)

    let effects = machine.handle(.fnPressed)

    try expect(machine.phase, equals: .processing, "phase after second Fn press")
    try expect(
        effects,
        equals: [.stopRecordingAndTranscribe],
        "effects after second Fn press"
    )
}

private func testEscapeWhileListeningCancelsRecordingAndSchedulesReset() throws {
    var machine = DictationStateMachine(phase: .listening)

    let effects = machine.handle(.escapePressed)

    try expect(machine.phase, equals: .cancelled, "phase after Escape")
    try expect(
        effects,
        equals: [.cancelRecording, .scheduleReset(afterMilliseconds: 500)],
        "effects after Escape"
    )
}

private func testExplicitFinishWhileListeningBeginsProcessing() throws {
    var machine = DictationStateMachine(phase: .listening)

    let effects = machine.handle(.finishRequested)

    try expect(machine.phase, equals: .processing, "phase after explicit finish")
    try expect(
        effects,
        equals: [.stopRecordingAndTranscribe],
        "effects after explicit finish"
    )
}

private func testExplicitCancelWhileListeningCancelsRecording() throws {
    var machine = DictationStateMachine(phase: .listening)

    let effects = machine.handle(.cancelRequested)

    try expect(machine.phase, equals: .cancelled, "phase after explicit cancel")
    try expect(
        effects,
        equals: [.cancelRecording, .scheduleReset(afterMilliseconds: 500)],
        "effects after explicit cancel"
    )
}

private func testRepeatedExplicitFinishDoesNotStopTwice() throws {
    var machine = DictationStateMachine(phase: .listening)
    _ = machine.handle(.finishRequested)

    let duplicateEffects = machine.handle(.finishRequested)

    try expect(machine.phase, equals: .processing, "phase after duplicate explicit finish")
    try expect(duplicateEffects, equals: [], "duplicate explicit finish effects")
}

private func testTranscriptMovesProcessingToPolishing() throws {
    var machine = DictationStateMachine(phase: .processing)

    let effects = machine.handle(.transcriptionSucceeded("明天下午三点开会"))

    try expect(machine.phase, equals: .polishing, "phase after transcription")
    try expect(
        effects,
        equals: [.polishTranscript("明天下午三点开会")],
        "effects after transcription"
    )
}

private func testPolishedTranscriptMovesToInsertion() throws {
    var machine = DictationStateMachine(phase: .polishing)

    let effects = machine.handle(
        .transcriptPolished("明天下午三点开会")
    )

    try expect(machine.phase, equals: .inserting, "phase after cleanup")
    try expect(
        effects,
        equals: [.insertText("明天下午三点开会")],
        "effects after cleanup"
    )
}

private func testInsertionSuccessReturnsDirectlyToIdle() throws {
    var machine = DictationStateMachine(phase: .inserting)

    let effects = machine.handle(.insertionSucceeded)

    try expect(machine.phase, equals: .idle, "phase after insertion")
    try expect(
        effects,
        equals: [],
        "effects after insertion"
    )
}

private func testInsertionFailureCopiesRecoverableText() throws {
    var machine = DictationStateMachine(phase: .inserting)

    let effects = machine.handle(
        .operationFailed(
            message: "未找到原输入框",
            recoveryText: "这段话不能丢"
        )
    )

    try expect(
        machine.phase,
        equals: .error(message: "未找到原输入框", recoveryText: "这段话不能丢"),
        "phase after recoverable insertion failure"
    )
    try expect(
        effects,
        equals: [
            .copyToClipboard("这段话不能丢"),
            .scheduleReset(afterMilliseconds: 4_000)
        ],
        "effects after recoverable insertion failure"
    )
}

private func testProviderFailureShowsErrorThenResets() throws {
    var machine = DictationStateMachine(phase: .processing)

    let effects = machine.handle(
        .operationFailed(message: "无法连接语音服务", recoveryText: nil)
    )

    try expect(
        machine.phase,
        equals: .error(message: "无法连接语音服务", recoveryText: nil),
        "phase after provider failure"
    )
    try expect(
        effects,
        equals: [.scheduleReset(afterMilliseconds: 4_000)],
        "provider failure reset effect"
    )
}

private func testNoSpeechWhileProcessingReturnsDirectlyToIdle() throws {
    var machine = DictationStateMachine(phase: .processing)

    let effects = machine.handle(.noSpeechDetected)

    try expect(machine.phase, equals: .idle, "phase after no speech")
    try expect(effects, equals: [], "no speech effects")
}

private func testEmptyDictationTreatsBadInputWithoutTranscriptAsNoSpeech() throws {
    try expect(
        EmptyDictationPolicy.shouldSilentlyDiscard(
            failureKind: .badInput,
            hasRecognizedContent: false
        ),
        equals: true,
        "bad input without recognized content"
    )
}

private func testEmptyDictationKeepsRealServiceFailuresVisible() throws {
    try expect(
        EmptyDictationPolicy.shouldSilentlyDiscard(
            failureKind: .unauthorized,
            hasRecognizedContent: false
        ),
        equals: false,
        "authorization failure without recognized content"
    )
    try expect(
        EmptyDictationPolicy.shouldSilentlyDiscard(
            failureKind: .badInput,
            hasRecognizedContent: true
        ),
        equals: false,
        "bad input after recognized content"
    )
}

private func testEmptyDictationDiscardsOnlyTrulyTinyLocalCapture() throws {
    try expect(
        EmptyDictationPolicy.isTriviallyShortPCM16(
            byteCount: 0,
            sampleRate: 16_000
        ),
        equals: true,
        "zero-byte capture"
    )
    try expect(
        EmptyDictationPolicy.isTriviallyShortPCM16(
            byteCount: 3_199,
            sampleRate: 16_000
        ),
        equals: true,
        "sub-frame capture"
    )
    try expect(
        EmptyDictationPolicy.isTriviallyShortPCM16(
            byteCount: 3_200,
            sampleRate: 16_000
        ),
        equals: false,
        "complete 100ms frame"
    )
}

private func testFirstMicrophoneAuthorizationUsesSystemPrompt() throws {
    let action = PermissionPolicy.action(
        for: .microphone,
        state: .notDetermined
    )

    try expect(action, equals: .request, "first microphone permission action")
}

private func testDeniedMicrophoneAuthorizationOpensSettings() throws {
    let action = PermissionPolicy.action(
        for: .microphone,
        state: .denied
    )

    try expect(action, equals: .openSystemSettings, "denied microphone action")
}

private func testRestrictedPermissionCannotBeRequestedAgain() throws {
    let action = PermissionPolicy.action(
        for: .microphone,
        state: .restricted
    )

    try expect(action, equals: .unavailable, "restricted permission action")
}

private func testMisconfiguredBuildNeverRequestsMicrophone() throws {
    let action = PermissionPolicy.action(
        for: .microphone,
        state: .misconfigured
    )

    try expect(action, equals: .unavailable, "misconfigured build action")
}

private func testDeniedSystemPermissionsOpenTheirSettingsPanes() throws {
    try expect(
        PermissionPolicy.action(for: .accessibility, state: .denied),
        equals: .openSystemSettings,
        "accessibility permission action"
    )
    try expect(
        PermissionPolicy.action(for: .inputMonitoring, state: .denied),
        equals: .openSystemSettings,
        "input monitoring permission action"
    )
}

private func testFirstSystemPermissionAuthorizationUsesNativePrompt() throws {
    try expect(
        PermissionPolicy.action(for: .accessibility, state: .notDetermined),
        equals: .request,
        "first accessibility permission action"
    )
    try expect(
        PermissionPolicy.action(for: .inputMonitoring, state: .notDetermined),
        equals: .request,
        "first input monitoring permission action"
    )
}

private func testSystemPermissionBecomesDeniedAfterNativeRequest() throws {
    try expect(
        PermissionPolicy.unresolvedSystemState(requestAttempted: false),
        equals: .notDetermined,
        "system permission state before native request"
    )
    try expect(
        PermissionPolicy.unresolvedSystemState(requestAttempted: true),
        equals: .denied,
        "system permission state after native request"
    )
}

private func testAccessibilityPermissionEnablesFnMonitoring() throws {
    try expect(
        PermissionPolicy.canMonitorFn(
            accessibility: .granted,
            inputMonitoring: .denied
        ),
        equals: true,
        "accessibility should cover Fn event listening"
    )
    try expect(
        PermissionPolicy.canMonitorFn(
            accessibility: .denied,
            inputMonitoring: .denied
        ),
        equals: false,
        "Fn monitoring without either permission"
    )
}

private func testFnPressIsIgnoredDuringProcessing() throws {
    var machine = DictationStateMachine(phase: .processing)

    let effects = machine.handle(.fnPressed)

    try expect(machine.phase, equals: .processing, "processing phase remains")
    try expect(effects, equals: [], "no duplicate recording effect")
}

private func testResetReturnsTransientPhaseToIdle() throws {
    var machine = DictationStateMachine(phase: .cancelled)

    let effects = machine.handle(.resetRequested)

    try expect(machine.phase, equals: .idle, "phase after reset")
    try expect(effects, equals: [], "reset effects")
}

private func testFnGestureArmsBeforeToggling() throws {
    var interpreter = FnGestureInterpreter()

    let action = interpreter.handle(.fnChanged(isDown: true, hasOtherModifiers: false))

    try expect(action, equals: .scheduleActivation(afterMilliseconds: 120), "Fn arm action")
}

private func testQuickStandaloneFnTapTogglesOnRelease() throws {
    var interpreter = FnGestureInterpreter()
    _ = interpreter.handle(.fnChanged(isDown: true, hasOtherModifiers: false))

    let action = interpreter.handle(.fnChanged(isDown: false, hasOtherModifiers: false))

    try expect(action, equals: .activateToggle, "quick Fn tap action")
}

private func testHeldStandaloneFnTogglesOnceAfterDeadline() throws {
    var interpreter = FnGestureInterpreter()
    _ = interpreter.handle(.fnChanged(isDown: true, hasOtherModifiers: false))

    let deadlineAction = interpreter.handle(.activationDeadlineReached)
    let releaseAction = interpreter.handle(.fnChanged(isDown: false, hasOtherModifiers: false))

    try expect(deadlineAction, equals: .activateToggle, "held Fn deadline action")
    try expect(releaseAction, equals: .none, "held Fn release action")
}

private func testFnCombinationCancelsPendingToggle() throws {
    var interpreter = FnGestureInterpreter()
    _ = interpreter.handle(.fnChanged(isDown: true, hasOtherModifiers: false))

    let keyAction = interpreter.handle(.nonModifierKeyPressed)
    let deadlineAction = interpreter.handle(.activationDeadlineReached)
    let releaseAction = interpreter.handle(.fnChanged(isDown: false, hasOtherModifiers: false))

    try expect(keyAction, equals: .cancelPendingActivation, "Fn combination cancellation")
    try expect(deadlineAction, equals: .none, "cancelled deadline action")
    try expect(releaseAction, equals: .none, "suppressed Fn release action")
}

private func testFnWithAnotherModifierNeverArms() throws {
    var interpreter = FnGestureInterpreter()

    let action = interpreter.handle(.fnChanged(isDown: true, hasOtherModifiers: true))

    try expect(action, equals: .none, "modified Fn action")
}

private func testTranscriptGuardAcceptsConservativeCleanup() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "嗯，明天下午 3:30 给 Alex 发邮件，预算是 ¥1,280。",
        polished: "明天下午 3:30 给 Alex 发邮件，预算是 ¥1,280。"
    )

    try expect(
        decision,
        equals: .usePolished("明天下午 3:30 给 Alex 发邮件，预算是 ¥1,280。"),
        "conservative cleanup decision"
    )
}

private func testTranscriptGuardRejectsChangedNumber() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "预算是 1280 元",
        polished: "预算是 1820 元。"
    )

    try expect(
        decision,
        equals: .useOriginal("预算是 1280 元", reason: .protectedTokenChanged),
        "changed number decision"
    )
}

private func testTranscriptGuardAcceptsExplicitNumberCorrection() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "我们6点吃饭，不对，改成8点",
        polished: "我们8点吃饭。"
    )

    try expect(
        decision,
        equals: .usePolished("我们8点吃饭。"),
        "explicit number correction decision"
    )
}

private func testTranscriptGuardRejectsUnpromptedChineseAdjacentNumberChange() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "我们6点吃饭",
        polished: "我们8点吃饭。"
    )

    try expect(
        decision,
        equals: .useOriginal("我们6点吃饭", reason: .protectedTokenChanged),
        "unprompted Chinese-adjacent number change decision"
    )
}

private func testTranscriptGuardRejectsProtectedTokenReassignment() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "张三转100元，李四转200元",
        polished: "张三转200元，李四转100元。"
    )

    try expect(
        decision,
        equals: .useOriginal("张三转100元，李四转200元", reason: .protectedTokenChanged),
        "protected token reassignment decision"
    )
}

private func testTranscriptGuardRejectsChangedURL() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "打开 https://example.com/a",
        polished: "打开 https://example.com/b。"
    )

    try expect(
        decision,
        equals: .useOriginal("打开 https://example.com/a", reason: .protectedTokenChanged),
        "changed URL decision"
    )
}

private func testTranscriptGuardRejectsChangedEmail() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "发给 alex@example.com",
        polished: "发给 alice@example.com。"
    )

    try expect(
        decision,
        equals: .useOriginal("发给 alex@example.com", reason: .protectedTokenChanged),
        "changed email decision"
    )
}

private func testTranscriptGuardRejectsEmptyOutput() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(raw: "不要丢失这句话", polished: "   ")

    try expect(
        decision,
        equals: .useOriginal("不要丢失这句话", reason: .emptyOutput),
        "empty output decision"
    )
}

private func testTranscriptGuardRejectsExtremeExpansion() throws {
    let guardrail = TranscriptGuard()

    let decision = guardrail.evaluate(
        raw: "明天开会",
        polished: "明天开会。会议将讨论市场战略、预算安排、团队规划以及未来三年的所有业务目标。"
    )

    try expect(
        decision,
        equals: .useOriginal("明天开会", reason: .excessiveExpansion),
        "expanded output decision"
    )
}

private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = data[offset..<(offset + 4)]
    return bytes.enumerated().reduce(0) { value, item in
        value | (UInt32(item.element) << UInt32(item.offset * 8))
    }
}

private func testWAVEncoderBuildsCanonicalPCM16Header() throws {
    let pcm = Data([0x00, 0x01, 0x02, 0x03])

    let wav = try PCM16WAVEncoder().encode(
        pcm,
        sampleRate: 16_000,
        channelCount: 1
    )

    try expect(String(data: wav[0..<4], encoding: .ascii), equals: "RIFF", "RIFF marker")
    try expect(littleEndianUInt32(wav, at: 4), equals: 40, "RIFF payload size")
    try expect(String(data: wav[8..<12], encoding: .ascii), equals: "WAVE", "WAVE marker")
    try expect(littleEndianUInt32(wav, at: 24), equals: 16_000, "sample rate")
    try expect(littleEndianUInt32(wav, at: 40), equals: 4, "audio byte count")
    try expect(Array(wav.suffix(4)), equals: Array(pcm), "PCM payload")
}

private func jsonDictionary(_ data: Data) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TestFailure(description: "Expected a JSON object")
    }
    return dictionary
}

private func testFunRunTaskMessageUsesDuplexPCM16Configuration() throws {
    let data = try FunASRWire.makeRunTask(
        taskID: "0123456789abcdef0123456789abcdef",
        configuration: ASRConfiguration(
            language: .automatic,
            sampleRate: 16_000,
            maxSentenceSilenceMilliseconds: 1_300
        )
    )
    let root = try jsonDictionary(data)
    let header = root["header"] as? [String: Any]
    let payload = root["payload"] as? [String: Any]
    let parameters = payload?["parameters"] as? [String: Any]

    try expect(header?["action"] as? String, equals: "run-task", "run task action")
    try expect(header?["streaming"] as? String, equals: "duplex", "duplex mode")
    try expect(payload?["model"] as? String, equals: "fun-asr-realtime", "Fun model")
    try expect(parameters?["format"] as? String, equals: "pcm", "Fun audio format")
    try expect(parameters?["sample_rate"] as? Int, equals: 16_000, "Fun sample rate")
    try expect(
        parameters?["max_sentence_silence"] as? Int,
        equals: 1_300,
        "Fun sentence silence"
    )
}

private func testFunFinishTaskMessageKeepsTaskIdentity() throws {
    let data = try FunASRWire.makeFinishTask(taskID: "task-42")
    let root = try jsonDictionary(data)
    let header = root["header"] as? [String: Any]

    try expect(header?["action"] as? String, equals: "finish-task", "finish task action")
    try expect(header?["task_id"] as? String, equals: "task-42", "finish task identity")
}

private func testFunServerEventDecodesFinalSentence() throws {
    let fixture = Data(
        #"{"header":{"event":"result-generated","task_id":"abc"},"payload":{"output":{"sentence":{"text":"明天下午三点。","heartbeat":false,"sentence_end":true,"sentence_id":2}},"usage":{"duration":3}}}"#.utf8
    )

    let event = try FunASRWire.decodeServerEvent(fixture)

    try expect(
        event,
        equals: .transcript(
            sentenceID: 2,
            text: "明天下午三点。",
            isFinal: true,
            billedSeconds: 3
        ),
        "Fun final sentence event"
    )
}

private func testFunTranscriptAssemblerReplacesPartialAndCommitsFinal() throws {
    var assembler = FunTranscriptAssembler()

    let first = assembler.apply(
        .transcript(sentenceID: 1, text: "明天下", isFinal: false, billedSeconds: nil)
    )
    let second = assembler.apply(
        .transcript(sentenceID: 1, text: "明天下午。", isFinal: true, billedSeconds: 1)
    )
    let third = assembler.apply(
        .transcript(sentenceID: 2, text: "三点", isFinal: false, billedSeconds: nil)
    )

    try expect(first, equals: "明天下", "first partial snapshot")
    try expect(second, equals: "明天下午。", "committed sentence snapshot")
    try expect(third, equals: "明天下午。三点", "next partial snapshot")
}

private func testMiMoRequestContainsBufferedWAVAndLanguage() throws {
    let wav = Data([0x52, 0x49, 0x46, 0x46])

    let data = try MiMoASRWire.makeRequest(
        wav: wav,
        language: .automatic,
        streamResponse: true
    )
    let root = try jsonDictionary(data)
    let messages = root["messages"] as? [[String: Any]]
    let content = messages?.first?["content"] as? [[String: Any]]
    let inputAudio = content?.first?["input_audio"] as? [String: Any]
    let options = root["asr_options"] as? [String: Any]

    try expect(root["model"] as? String, equals: "mimo-v2.5-asr", "MiMo model")
    try expect(root["stream"] as? Bool, equals: true, "MiMo stream response flag")
    try expect(options?["language"] as? String, equals: "auto", "MiMo language")
    try expect(
        inputAudio?["data"] as? String,
        equals: "data:audio/wav;base64,UklGRg==",
        "MiMo WAV data URL"
    )
}

private func testMiMoSSEParserDecodesTextDeltaAndDone() throws {
    let deltaLine = #"data: {"choices":[{"delta":{"content":"明天下午"},"finish_reason":null}]}"#

    let delta = try MiMoASRWire.decodeSSELine(deltaLine)
    let done = try MiMoASRWire.decodeSSELine("data: [DONE]")

    try expect(delta, equals: .delta("明天下午"), "MiMo SSE delta")
    try expect(done, equals: .done, "MiMo SSE done")
}

private func testMiMoStatusMapperMarksRateLimitRetryable() throws {
    let failure = MiMoASRWire.failure(forHTTPStatus: 429, message: "Too many requests")

    try expect(failure.kind, equals: .rateLimited, "MiMo rate limit kind")
    try expect(failure.retryable, equals: true, "MiMo rate limit retryability")
}

private func testPCMChunkerEmitsFullFramesAndDrainsRemainder() throws {
    var chunker = PCMChunker(frameByteCount: 3_200)
    let firstInput = Data(repeating: 0x11, count: 2_000)
    let secondInput = Data(repeating: 0x22, count: 2_000)

    let firstFrames = chunker.append(firstInput)
    let secondFrames = chunker.append(secondInput)
    let remainder = chunker.drain()

    try expect(firstFrames.count, equals: 0, "no premature PCM frame")
    try expect(secondFrames.count, equals: 1, "one complete PCM frame")
    try expect(secondFrames[0].count, equals: 3_200, "complete PCM frame size")
    try expect(Array(secondFrames[0].prefix(2_000)), equals: Array(firstInput), "frame prefix")
    try expect(remainder.count, equals: 800, "PCM remainder size")
    try expect(Array(remainder), equals: Array(Data(repeating: 0x22, count: 800)), "PCM remainder")
}

private func testPCMChunkerDrainsZeroRemainderWhileFrameIsRetained() throws {
    var chunker = PCMChunker(frameByteCount: 3_200)
    let frames = chunker.append(Data(repeating: 0x33, count: 3_200))

    let remainder = withExtendedLifetime(frames) {
        chunker.drain()
    }

    try expect(frames.count, equals: 1, "one exact PCM frame")
    try expect(frames[0].count, equals: 3_200, "retained PCM frame size")
    try expect(remainder.isEmpty, equals: true, "zero PCM remainder")
}

private func testInsertionStrategyRejectsSecureTarget() throws {
    let target = InsertionTargetCapabilities(
        isSameFocusedElement: true,
        isSecure: true,
        isNativeTextControl: true,
        valueIsWritable: true,
        hasSelectedTextRange: true
    )

    try expect(
        InsertionStrategyResolver.resolve(target),
        equals: .copyOnly(reason: .secureField),
        "secure target strategy"
    )
}

private func testInsertionStrategyUsesDirectReplacementForNativeText() throws {
    let target = InsertionTargetCapabilities(
        isSameFocusedElement: true,
        isSecure: false,
        isNativeTextControl: true,
        valueIsWritable: true,
        hasSelectedTextRange: true
    )

    try expect(
        InsertionStrategyResolver.resolve(target),
        equals: .directValueReplacement,
        "native text strategy"
    )
}

private func testInsertionStrategyUsesPasteForRichText() throws {
    let target = InsertionTargetCapabilities(
        isSameFocusedElement: true,
        isSecure: false,
        isNativeTextControl: false,
        valueIsWritable: false,
        hasSelectedTextRange: false
    )

    try expect(
        InsertionStrategyResolver.resolve(target),
        equals: .pasteboard,
        "rich text strategy"
    )
}

private func testInsertionStrategyUsesPasteForCodexProseMirror() throws {
    let target = InsertionTargetCapabilities(
        isSameFocusedElement: true,
        isSecure: false,
        isNativeTextControl: true,
        valueIsWritable: true,
        hasSelectedTextRange: true
    )

    try expect(
        InsertionStrategyResolver.resolve(
            target,
            source: .codexProseMirror
        ),
        equals: .pasteboard,
        "Codex ProseMirror strategy"
    )
}

private func testInsertionStrategyCopiesWhenFocusChanged() throws {
    let target = InsertionTargetCapabilities(
        isSameFocusedElement: false,
        isSecure: false,
        isNativeTextControl: true,
        valueIsWritable: true,
        hasSelectedTextRange: true
    )

    try expect(
        InsertionStrategyResolver.resolve(target),
        equals: .copyOnly(reason: .focusChanged),
        "changed focus strategy"
    )
}

private func testFocusedTextFallbackAcceptsOnlyFocusedTextControls() throws {
    try expect(
        FocusedTextCandidatePolicy.isEligible(
            role: "AXTextArea",
            isFocused: true
        ),
        equals: true,
        "focused text area fallback"
    )
    try expect(
        FocusedTextCandidatePolicy.isEligible(
            role: "AXTextField",
            isFocused: true
        ),
        equals: true,
        "focused text field fallback"
    )
    try expect(
        FocusedTextCandidatePolicy.isEligible(
            role: "AXComboBox",
            isFocused: true
        ),
        equals: true,
        "focused combo box fallback"
    )
    try expect(
        FocusedTextCandidatePolicy.isEligible(
            role: "AXTextArea",
            isFocused: false
        ),
        equals: false,
        "unfocused text area fallback"
    )
    try expect(
        FocusedTextCandidatePolicy.isEligible(
            role: "AXButton",
            isFocused: true
        ),
        equals: false,
        "focused non-text control fallback"
    )
}

private func testWindowFocusFallbackUsesFrontmostNormalWindow() throws {
    let candidates = [
        WindowFocusCandidate(
            processID: 91,
            layer: 25,
            alpha: 1,
            width: 320,
            height: 48
        ),
        WindowFocusCandidate(
            processID: 101,
            layer: 0,
            alpha: 1,
            width: 1_710,
            height: 1_073
        ),
        WindowFocusCandidate(
            processID: 202,
            layer: 0,
            alpha: 1,
            width: 1_710,
            height: 1_073
        )
    ]

    try expect(
        WindowFocusCandidatePolicy.frontmostNormalProcessID(
            candidates,
            excluding: 999
        ),
        equals: 101,
        "frontmost normal window process"
    )
    try expect(
        WindowFocusCandidatePolicy.frontmostNormalProcessID(
            candidates,
            excluding: 101
        ),
        equals: nil,
        "do not fall through behind Sotto's own normal window"
    )
}

private func testCodexTargetDoesNotFollowAnotherProseMirror() throws {
    try expect(
        TextTargetIdentityPolicy.isSameTarget(
            sameElement: true
        ),
        equals: true,
        "same Codex AX element"
    )
    try expect(
        TextTargetIdentityPolicy.isSameTarget(
            sameElement: false
        ),
        equals: false,
        "another ProseMirror in the same window"
    )
}

private func testOverlayCopyUsesThinkingForProcessing() throws {
    try expect(
        DictationOverlayCopy.thinking,
        equals: "Thinking…",
        "processing overlay copy"
    )
}

private func testInsertionHasNoOverlayPresentation() throws {
    try expect(
        DictationOverlayPresentation.resolve(.inserting),
        equals: nil,
        "insertion presentation"
    )
}

private func testProcessingAndPolishingUseThinkingBeforeDismissal() throws {
    try expect(
        DictationOverlayPresentation.resolve(.processing),
        equals: .thinking,
        "processing presentation"
    )
    try expect(
        DictationOverlayPresentation.resolve(.polishing),
        equals: .thinking,
        "cleanup presentation"
    )
    try expect(
        DictationOverlayPresentation.resolve(.inserting),
        equals: nil,
        "inserting has no presentation"
    )
    try expect(
        DictationOverlayPresentation.resolve(.success),
        equals: nil,
        "successful insertion has no confirmation presentation"
    )
}

private func testOverlayDismissalWaitsUntilPanelIsHidden() throws {
    try expect(
        OverlayDismissalReadinessPolicy.resolve(
            expectedGeneration: 7,
            currentGeneration: 7,
            readyGeneration: nil,
            isPanelVisible: true,
            hasTimedOut: false
        ),
        equals: .waiting,
        "Thinking dismissal still animating"
    )
    try expect(
        OverlayDismissalReadinessPolicy.resolve(
            expectedGeneration: 7,
            currentGeneration: 7,
            readyGeneration: 7,
            isPanelVisible: false,
            hasTimedOut: false
        ),
        equals: .ready,
        "Thinking presentation dismissed"
    )
}

private func testOverlayDismissalFailsClosed() throws {
    try expect(
        OverlayDismissalReadinessPolicy.resolve(
            expectedGeneration: 7,
            currentGeneration: 8,
            readyGeneration: nil,
            isPanelVisible: true,
            hasTimedOut: false
        ),
        equals: .unavailable,
        "different presentation generation"
    )
    try expect(
        OverlayDismissalReadinessPolicy.resolve(
            expectedGeneration: 7,
            currentGeneration: 7,
            readyGeneration: nil,
            isPanelVisible: true,
            hasTimedOut: true
        ),
        equals: .unavailable,
        "dismissal timeout"
    )
}

private func testClipboardRecoveryNamesMacPasteShortcut() throws {
    try expect(
        ClipboardRecoveryCopy.pasteShortcut,
        equals: "⌘V",
        "macOS paste shortcut"
    )
    try expect(
        ClipboardRecoveryCopy.message(
            reason: "未识别到输入框"
        ),
        equals: "未识别到输入框，已复制，请按 ⌘V 粘贴",
        "clipboard recovery message"
    )
    try expect(
        ClipboardRecoveryCopy.uncertainDeliveryMessage,
        equals: "已复制；若未写入，请按 ⌘V 粘贴",
        "uncertain delivery avoids duplicate paste"
    )
}

private func testBailianWorkspaceInputExtractsIDFromConsoleAPIHost() throws {
    let workspaceID = BailianWorkspaceInput.normalizedID(
        from: "https://llm-exampleworkspace123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    )

    try expect(
        workspaceID,
        equals: "llm-exampleworkspace123",
        "workspace ID parsed from Bailian console host"
    )
}

private func testFunConnectionRouteUsesSharedEndpointAndWorkspaceHeader() throws {
    let route = FunASRConnectionRoute.resolve(
        region: .mainlandChina,
        workspaceInput: "https://llm-exampleworkspace123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    )

    try expect(
        route?.endpoint.absoluteString,
        equals: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/",
        "Fun-ASR realtime endpoint"
    )
    try expect(
        route?.workspaceHeaderValue,
        equals: "llm-exampleworkspace123",
        "Fun-ASR workspace header"
    )
}

private func testBailianCleanupRouteReusesWorkspaceAndRegion() throws {
    let route = BailianCleanupRoute.resolve(
        region: .mainlandChina,
        workspaceInput: "https://llm-exampleworkspace123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    )

    try expect(
        route?.endpoint.absoluteString,
        equals: "https://llm-exampleworkspace123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions",
        "Bailian cleanup endpoint"
    )
    try expect(
        route?.model,
        equals: "qwen3.5-flash",
        "Bailian cleanup model"
    )
}

private func testBailianCleanupIsEnabledByDefault() throws {
    try expect(
        BailianCleanupPolicy.enabledByDefault,
        equals: true,
        "Bailian cleanup default"
    )
}

private func testBailianCleanupRequestDisablesThinkingAndEncodesCorrectionRule() throws {
    let data = try BailianCleanupWire.makeRequest(
        rawTranscript: "今晚6点吃饭，哦不，改成8点。"
    )
    let root = try jsonDictionary(data)
    let messages = root["messages"] as? [[String: Any]]

    try expect(root["model"] as? String, equals: "qwen3.5-flash", "cleanup model")
    try expect(root["enable_thinking"] as? Bool, equals: false, "cleanup thinking mode")
    try expect(root["temperature"] as? Double, equals: 0, "cleanup temperature")
    try expect(root["max_tokens"] as? Int, equals: 1_024, "cleanup output limit")
    try expect(messages?.first?["role"] as? String, equals: "system", "cleanup system role")
    try expect(
        (messages?.first?["content"] as? String)?.contains("superseded value") ?? false,
        equals: true,
        "cleanup explicit correction rule"
    )
    try expect(
        (messages?.last?["content"] as? String)?.contains("今晚6点吃饭，哦不，改成8点。") ?? false,
        equals: true,
        "cleanup raw transcript payload"
    )
}

private func testFunFailureMapperRecognizesHyphenatedInvalidAPIKey() throws {
    let failure = FunASRFailureMapper.providerFailure(
        code: "InvalidApiKey",
        message: "Invalid API-key provided."
    )

    try expect(failure.kind, equals: .unauthorized, "InvalidApiKey failure kind")
    try expect(failure.providerCode, equals: "InvalidApiKey", "InvalidApiKey code")
}

private func testFunFailureMapperOnlyMarksExplicitAudioErrorsAsBadInput() throws {
    let failure = FunASRFailureMapper.providerFailure(
        code: "Audio.DecoderError",
        message: "Decoder audio stream failed."
    )

    try expect(failure.kind, equals: .badInput, "audio decoder failure kind")
}

private func testFunFailureMapperPreservesRateLimitSemantics() throws {
    let failure = FunASRFailureMapper.providerFailure(
        code: "Throttling.RateQuota",
        message: "Requests throttling triggered."
    )

    try expect(failure.kind, equals: .rateLimited, "rate limit failure kind")
    try expect(failure.retryable, equals: true, "rate limit retryability")
}

private func testFunFailureMapperRecognizesArrearage() throws {
    let failure = FunASRFailureMapper.providerFailure(
        code: "Arrearage",
        message: "Access denied, please make sure your account is in good standing."
    )

    try expect(failure.kind, equals: .insufficientBalance, "arrearage failure kind")
}

private func testFunFailureMapperRecognizesWorkspaceAccessDenied() throws {
    let failure = FunASRFailureMapper.providerFailure(
        code: "Workspace.AccessDenied",
        message: "Access denied for this workspace."
    )

    try expect(failure.kind, equals: .unauthorized, "workspace access failure kind")
}

private func testFailurePresenterDoesNotDescribeAuthFailureAsAudioFormat() throws {
    let failure = ASRFailure(
        kind: .unauthorized,
        providerCode: "InvalidApiKey",
        message: "Invalid API-key provided.",
        retryable: false
    )

    try expect(
        ASRFailurePresenter.userMessage(for: failure, serviceName: "百炼"),
        equals: "百炼鉴权失败，请检查 API Key、API Host 和区域",
        "auth failure presentation"
    )
}

private func testFailurePresenterKeepsProviderDiagnosticDetails() throws {
    let failure = ASRFailure(
        kind: .unauthorized,
        providerCode: "InvalidApiKey",
        message: "Invalid API-key provided.",
        retryable: false
    )

    try expect(
        ASRFailurePresenter.diagnosticSummary(for: failure),
        equals: "InvalidApiKey · Invalid API-key provided.",
        "provider diagnostic summary"
    )
}

private func testKeyboardSettingsLinkTargetsNativeKeyboardPane() throws {
    try expect(
        SystemSettingsLink.keyboard.absoluteString,
        equals: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "keyboard settings URL"
    )
}

private func testStandardAppUsesRegularActivationPolicy() throws {
    try expect(
        AppPresentationPolicy.activationMode,
        equals: .regular,
        "standard app activation mode"
    )
}

private func testStandardAppShowsSettingsOnLaunchAndReopen() throws {
    try expect(
        AppPresentationPolicy.showsSettingsOnLaunch,
        equals: true,
        "show settings on launch"
    )
    try expect(
        AppPresentationPolicy.showsSettingsOnReopen,
        equals: true,
        "show settings on reopen"
    )
}

private func testPasteDeliveryCannotClaimSuccessWithoutObservableChange() throws {
    try expect(
        PasteDeliveryVerifier.didInsert(
            text: "测试结果",
            valueBefore: nil,
            valueAfter: nil
        ),
        equals: false,
        "unobservable paste delivery"
    )
}

private func testTextReplacementTreatsExposedPlaceholderAsEmptyValue() throws {
    let result = TextReplacementComposer.replacing(
        currentValue: "随心输入",
        placeholderValue: "随心输入",
        selectedRange: NSRange(location: 0, length: 0),
        with: "你是不是弄复杂了？"
    )

    try expect(
        result,
        equals: "你是不是弄复杂了？",
        "exposed placeholder replacement"
    )
}

private func testTextReplacementTreatsCodexProseMirrorPlaceholderAsEmptyValue() throws {
    let result = TextReplacementComposer.replacing(
        currentValue: "\n随心输入",
        placeholderValue: nil,
        selectedRange: NSRange(location: 0, length: 0),
        with: "这次不要带上 placeholder",
        source: .codexProseMirror
    )

    try expect(
        result,
        equals: "这次不要带上 placeholder",
        "Codex ProseMirror placeholder replacement"
    )
}

private func testTextReplacementPreservesLeadingLineOutsideCodexProseMirror() throws {
    let result = TextReplacementComposer.replacing(
        currentValue: "\n这是真实第二行",
        placeholderValue: nil,
        selectedRange: NSRange(location: 0, length: 0),
        with: "开头",
        source: .standard
    )

    try expect(
        result,
        equals: "开头\n这是真实第二行",
        "standard leading line replacement"
    )
}

private func testTextReplacementPreservesRealExistingText() throws {
    let result = TextReplacementComposer.replacing(
        currentValue: "已有内容",
        placeholderValue: "随心输入",
        selectedRange: NSRange(location: 4, length: 0),
        with: "，继续说"
    )

    try expect(
        result,
        equals: "已有内容，继续说",
        "real existing text replacement"
    )
}

private func testTextReplacementPreservesTypedTextMatchingPlaceholder() throws {
    let result = TextReplacementComposer.replacing(
        currentValue: "随心输入",
        placeholderValue: "随心输入",
        selectedRange: NSRange(location: 4, length: 0),
        with: "，是真的文字"
    )

    try expect(
        result,
        equals: "随心输入，是真的文字",
        "typed placeholder-matching text replacement"
    )
}

private func testFunConfigurationRequiresWorkspaceHost() throws {
    try expect(
        FunASRConfigurationPolicy.isReady(
            hasAPIKey: true,
            workspaceInput: ""
        ),
        equals: false,
        "Fun-ASR configuration without workspace host"
    )
}

@main
private enum SottoCoreTestHarness {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            (
                "Fn press from idle begins listening and requests recording",
                testFnPressFromIdleBeginsListeningAndRequestsRecording
            ),
            (
                "Fn press while listening stops recording and begins processing",
                testFnPressWhileListeningStopsRecordingAndBeginsProcessing
            ),
            (
                "Escape while listening cancels recording and schedules reset",
                testEscapeWhileListeningCancelsRecordingAndSchedulesReset
            ),
            (
                "Explicit finish while listening begins processing",
                testExplicitFinishWhileListeningBeginsProcessing
            ),
            (
                "Explicit cancel while listening cancels recording",
                testExplicitCancelWhileListeningCancelsRecording
            ),
            (
                "Repeated explicit finish does not stop twice",
                testRepeatedExplicitFinishDoesNotStopTwice
            ),
            (
                "Transcript moves processing to polishing",
                testTranscriptMovesProcessingToPolishing
            ),
            (
                "Polished transcript moves to insertion",
                testPolishedTranscriptMovesToInsertion
            ),
            (
                "Insertion success returns directly to idle",
                testInsertionSuccessReturnsDirectlyToIdle
            ),
            (
                "Insertion failure copies recoverable text",
                testInsertionFailureCopiesRecoverableText
            ),
            (
                "Provider failure shows error then resets",
                testProviderFailureShowsErrorThenResets
            ),
            (
                "No speech while processing returns directly to idle",
                testNoSpeechWhileProcessingReturnsDirectlyToIdle
            ),
            (
                "Empty dictation treats bad input without transcript as no speech",
                testEmptyDictationTreatsBadInputWithoutTranscriptAsNoSpeech
            ),
            (
                "Empty dictation keeps real service failures visible",
                testEmptyDictationKeepsRealServiceFailuresVisible
            ),
            (
                "Empty dictation discards only truly tiny local capture",
                testEmptyDictationDiscardsOnlyTrulyTinyLocalCapture
            ),
            (
                "First microphone authorization uses system prompt",
                testFirstMicrophoneAuthorizationUsesSystemPrompt
            ),
            (
                "Denied microphone authorization opens Settings",
                testDeniedMicrophoneAuthorizationOpensSettings
            ),
            (
                "Restricted permission cannot be requested again",
                testRestrictedPermissionCannotBeRequestedAgain
            ),
            (
                "Misconfigured build never requests microphone",
                testMisconfiguredBuildNeverRequestsMicrophone
            ),
            (
                "Denied system permissions open their Settings panes",
                testDeniedSystemPermissionsOpenTheirSettingsPanes
            ),
            (
                "First system permission authorization uses native prompt",
                testFirstSystemPermissionAuthorizationUsesNativePrompt
            ),
            (
                "System permission becomes denied after native request",
                testSystemPermissionBecomesDeniedAfterNativeRequest
            ),
            (
                "Accessibility permission enables Fn monitoring",
                testAccessibilityPermissionEnablesFnMonitoring
            ),
            (
                "Fn press is ignored during processing",
                testFnPressIsIgnoredDuringProcessing
            ),
            (
                "Reset returns transient phase to idle",
                testResetReturnsTransientPhaseToIdle
            ),
            (
                "Fn gesture arms before toggling",
                testFnGestureArmsBeforeToggling
            ),
            (
                "Quick standalone Fn tap toggles on release",
                testQuickStandaloneFnTapTogglesOnRelease
            ),
            (
                "Held standalone Fn toggles once after deadline",
                testHeldStandaloneFnTogglesOnceAfterDeadline
            ),
            (
                "Fn combination cancels pending toggle",
                testFnCombinationCancelsPendingToggle
            ),
            (
                "Fn with another modifier never arms",
                testFnWithAnotherModifierNeverArms
            ),
            (
                "Transcript guard accepts conservative cleanup",
                testTranscriptGuardAcceptsConservativeCleanup
            ),
            (
                "Transcript guard rejects changed number",
                testTranscriptGuardRejectsChangedNumber
            ),
            (
                "Transcript guard accepts explicit number correction",
                testTranscriptGuardAcceptsExplicitNumberCorrection
            ),
            (
                "Transcript guard rejects unprompted Chinese-adjacent number change",
                testTranscriptGuardRejectsUnpromptedChineseAdjacentNumberChange
            ),
            (
                "Transcript guard rejects protected token reassignment",
                testTranscriptGuardRejectsProtectedTokenReassignment
            ),
            (
                "Transcript guard rejects changed URL",
                testTranscriptGuardRejectsChangedURL
            ),
            (
                "Transcript guard rejects changed email",
                testTranscriptGuardRejectsChangedEmail
            ),
            (
                "Transcript guard rejects empty output",
                testTranscriptGuardRejectsEmptyOutput
            ),
            (
                "Transcript guard rejects extreme expansion",
                testTranscriptGuardRejectsExtremeExpansion
            ),
            (
                "WAV encoder builds canonical PCM16 header",
                testWAVEncoderBuildsCanonicalPCM16Header
            ),
            (
                "Fun run task message uses duplex PCM16 configuration",
                testFunRunTaskMessageUsesDuplexPCM16Configuration
            ),
            (
                "Fun finish task message keeps task identity",
                testFunFinishTaskMessageKeepsTaskIdentity
            ),
            (
                "Fun server event decodes final sentence",
                testFunServerEventDecodesFinalSentence
            ),
            (
                "Fun transcript assembler replaces partial and commits final",
                testFunTranscriptAssemblerReplacesPartialAndCommitsFinal
            ),
            (
                "MiMo request contains buffered WAV and language",
                testMiMoRequestContainsBufferedWAVAndLanguage
            ),
            (
                "MiMo SSE parser decodes text delta and done",
                testMiMoSSEParserDecodesTextDeltaAndDone
            ),
            (
                "MiMo status mapper marks rate limit retryable",
                testMiMoStatusMapperMarksRateLimitRetryable
            ),
            (
                "PCM chunker emits full frames and drains remainder",
                testPCMChunkerEmitsFullFramesAndDrainsRemainder
            ),
            (
                "PCM chunker drains zero remainder while frame is retained",
                testPCMChunkerDrainsZeroRemainderWhileFrameIsRetained
            ),
            (
                "Insertion strategy rejects secure target",
                testInsertionStrategyRejectsSecureTarget
            ),
            (
                "Insertion strategy uses direct replacement for native text",
                testInsertionStrategyUsesDirectReplacementForNativeText
            ),
            (
                "Insertion strategy uses paste for rich text",
                testInsertionStrategyUsesPasteForRichText
            ),
            (
                "Insertion strategy uses paste for Codex ProseMirror",
                testInsertionStrategyUsesPasteForCodexProseMirror
            ),
            (
                "Insertion strategy copies when focus changed",
                testInsertionStrategyCopiesWhenFocusChanged
            ),
            (
                "Focused text fallback accepts only focused text controls",
                testFocusedTextFallbackAcceptsOnlyFocusedTextControls
            ),
            (
                "Window focus fallback uses frontmost normal window",
                testWindowFocusFallbackUsesFrontmostNormalWindow
            ),
            (
                "Codex target does not follow another ProseMirror",
                testCodexTargetDoesNotFollowAnotherProseMirror
            ),
            (
                "Overlay copy uses Thinking for processing",
                testOverlayCopyUsesThinkingForProcessing
            ),
            (
                "Insertion has no overlay presentation",
                testInsertionHasNoOverlayPresentation
            ),
            (
                "Processing and polishing use Thinking before dismissal",
                testProcessingAndPolishingUseThinkingBeforeDismissal
            ),
            (
                "Overlay dismissal waits until panel is hidden",
                testOverlayDismissalWaitsUntilPanelIsHidden
            ),
            (
                "Overlay dismissal fails closed",
                testOverlayDismissalFailsClosed
            ),
            (
                "Clipboard recovery names macOS paste shortcut",
                testClipboardRecoveryNamesMacPasteShortcut
            ),
            (
                "Bailian workspace input extracts ID from console API host",
                testBailianWorkspaceInputExtractsIDFromConsoleAPIHost
            ),
            (
                "Fun connection route uses shared endpoint and workspace header",
                testFunConnectionRouteUsesSharedEndpointAndWorkspaceHeader
            ),
            (
                "Bailian cleanup route reuses workspace and region",
                testBailianCleanupRouteReusesWorkspaceAndRegion
            ),
            (
                "Bailian cleanup is enabled by default",
                testBailianCleanupIsEnabledByDefault
            ),
            (
                "Bailian cleanup request disables thinking and encodes correction rule",
                testBailianCleanupRequestDisablesThinkingAndEncodesCorrectionRule
            ),
            (
                "Fun failure mapper recognizes hyphenated InvalidApiKey",
                testFunFailureMapperRecognizesHyphenatedInvalidAPIKey
            ),
            (
                "Fun failure mapper marks explicit audio errors as bad input",
                testFunFailureMapperOnlyMarksExplicitAudioErrorsAsBadInput
            ),
            (
                "Fun failure mapper preserves rate limit semantics",
                testFunFailureMapperPreservesRateLimitSemantics
            ),
            (
                "Fun failure mapper recognizes arrearage",
                testFunFailureMapperRecognizesArrearage
            ),
            (
                "Fun failure mapper recognizes workspace access denied",
                testFunFailureMapperRecognizesWorkspaceAccessDenied
            ),
            (
                "Failure presenter does not describe auth failure as audio format",
                testFailurePresenterDoesNotDescribeAuthFailureAsAudioFormat
            ),
            (
                "Failure presenter keeps provider diagnostic details",
                testFailurePresenterKeepsProviderDiagnosticDetails
            ),
            (
                "Keyboard settings link targets native keyboard pane",
                testKeyboardSettingsLinkTargetsNativeKeyboardPane
            ),
            (
                "Standard app uses regular activation policy",
                testStandardAppUsesRegularActivationPolicy
            ),
            (
                "Standard app shows settings on launch and reopen",
                testStandardAppShowsSettingsOnLaunchAndReopen
            ),
            (
                "Paste delivery cannot claim success without observable change",
                testPasteDeliveryCannotClaimSuccessWithoutObservableChange
            ),
            (
                "Text replacement treats exposed placeholder as empty value",
                testTextReplacementTreatsExposedPlaceholderAsEmptyValue
            ),
            (
                "Text replacement treats Codex ProseMirror placeholder as empty value",
                testTextReplacementTreatsCodexProseMirrorPlaceholderAsEmptyValue
            ),
            (
                "Text replacement preserves leading line outside Codex ProseMirror",
                testTextReplacementPreservesLeadingLineOutsideCodexProseMirror
            ),
            (
                "Text replacement preserves real existing text",
                testTextReplacementPreservesRealExistingText
            ),
            (
                "Text replacement preserves typed text matching placeholder",
                testTextReplacementPreservesTypedTextMatchingPlaceholder
            ),
            (
                "Fun configuration requires workspace host",
                testFunConfigurationRequiresWorkspaceHost
            )
        ]
        var failures = 0

        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }

        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 {
            exit(1)
        }
    }
}
