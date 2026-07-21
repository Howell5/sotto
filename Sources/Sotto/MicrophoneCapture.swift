@preconcurrency import AVFoundation
import Accelerate
import Foundation

enum MicrophoneCaptureError: LocalizedError {
    case unavailable
    case conversionUnavailable
    case conversionFailed(String)
    case configurationChanged
    case maximumDurationReached

    var errorDescription: String? {
        switch self {
        case .unavailable: "没有可用的麦克风输入"
        case .conversionUnavailable: "无法创建 16 kHz 音频转换器"
        case let .conversionFailed(message): "音频转换失败：\(message)"
        case .configurationChanged: "录音时麦克风设备发生了变化"
        case .maximumDurationReached: "录音时间超过安全上限"
        }
    }
}

private final class PCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

// AVAudioConverter invokes its input block synchronously, but Swift 6 treats
// the block as potentially concurrent. Keeping the one-shot state in an
// explicitly sendable reference avoids capturing and mutating a local var.
private final class ConverterInputState: @unchecked Sendable {
    var consumed = false
}

private final class ConverterEndState: @unchecked Sendable {
    var signalledEnd = false
}

final class MicrophoneCapture: @unchecked Sendable {
    typealias PCMCallback = @Sendable (Data) -> Void
    typealias LevelCallback = @Sendable (Double) -> Void
    typealias ErrorCallback = @Sendable (Error) -> Void

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "com.sotto.audio.convert")
    private let tapCallbackGroup = DispatchGroup()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var capturedPCM = Data()
    private var onPCM: PCMCallback?
    private var onLevel: LevelCallback?
    private var onError: ErrorCallback?
    private var isRunning = false
    private var didReportMaximumDuration = false
    private var configurationObserver: NSObjectProtocol?
    // Provider-aware timers stop normally at 3/5 minutes. This is only a
    // hard safety ceiling if coordinator state is disrupted.
    private let maximumPCMBytes = 16_000 * 2 * 60 * 6

    func start(
        onPCM: @escaping PCMCallback,
        onLevel: @escaping LevelCallback,
        onError: @escaping ErrorCallback
    ) throws {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        self.onPCM = onPCM
        self.onLevel = onLevel
        self.onError = onError
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            resetRunningState()
            throw MicrophoneCaptureError.unavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            resetRunningState()
            throw MicrophoneCaptureError.conversionUnavailable
        }

        processingQueue.sync {
            self.outputFormat = outputFormat
            self.converter = converter
            self.capturedPCM.removeAll(keepingCapacity: true)
            self.didReportMaximumDuration = false
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.callbackSnapshot().error?(MicrophoneCaptureError.configurationChanged)
        }

        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: nil
        ) { [weak self] buffer, _ in
            self?.receiveTap(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            resetRunningState()
            throw error
        }
    }

    func stop() -> Data {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        let observer = configurationObserver
        configurationObserver = nil
        lock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // A tap callback that already began may not have queued its copied
        // buffer yet. Wait for those callbacks before placing the conversion
        // barrier, otherwise the final hardware buffer can land behind it.
        tapCallbackGroup.wait()

        let data = processingQueue.sync { () -> Data in
            drainConverterEndOfStream()
            let result = capturedPCM
            capturedPCM.removeAll(keepingCapacity: true)
            converter = nil
            outputFormat = nil
            return result
        }

        lock.lock()
        onPCM = nil
        onLevel = nil
        onError = nil
        lock.unlock()
        return data
    }

    private func receiveTap(_ buffer: AVAudioPCMBuffer) {
        tapCallbackGroup.enter()
        defer { tapCallbackGroup.leave() }

        lock.lock()
        let shouldAcceptBuffer = isRunning
        lock.unlock()
        guard shouldAcceptBuffer else { return }

        let callbacks = callbackSnapshot()
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
            let normalized = min(1, max(0, Double(rms) * 8))
            callbacks.level?(normalized)
        }

        guard let copy = copyBuffer(buffer) else { return }
        let box = PCMBufferBox(copy)
        processingQueue.async { [weak self, box] in
            self?.convert(box.buffer)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            if inputState.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.consumed = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error,
              conversionError == nil,
              output.frameLength > 0,
              let samples = output.int16ChannelData?[0]
        else {
            let message = conversionError?.localizedDescription ?? "unknown converter status"
            callbackSnapshot().error?(MicrophoneCaptureError.conversionFailed(message))
            return
        }

        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: samples, count: byteCount)
        deliver(data)
    }

    private func drainConverterEndOfStream() {
        guard let converter, let outputFormat else { return }
        let endState = ConverterEndState()

        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 256
            ) else { return }

            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                if endState.signalledEnd {
                    inputStatus.pointee = .noDataNow
                } else {
                    endState.signalledEnd = true
                    inputStatus.pointee = .endOfStream
                }
                return nil
            }

            if output.frameLength > 0, let samples = output.int16ChannelData?[0] {
                let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
                deliver(Data(bytes: samples, count: byteCount))
            }

            if status == .error {
                let message = conversionError?.localizedDescription
                    ?? "unknown converter drain status"
                callbackSnapshot().error?(MicrophoneCaptureError.conversionFailed(message))
                return
            }
            if status == .endOfStream || output.frameLength == 0 {
                return
            }
        }
    }

    private func deliver(_ data: Data) {
        if capturedPCM.count + data.count <= maximumPCMBytes {
            capturedPCM.append(data)
            callbackSnapshot().pcm?(data)
        } else if !didReportMaximumDuration {
            didReportMaximumDuration = true
            callbackSnapshot().error?(MicrophoneCaptureError.maximumDurationReached)
        }
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = source.mData, let destinationData = destination.mData else {
                continue
            }
            memcpy(destinationData, sourceData, Int(source.mDataByteSize))
        }
        return copy
    }

    private func callbackSnapshot() -> (
        pcm: PCMCallback?,
        level: LevelCallback?,
        error: ErrorCallback?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (onPCM, onLevel, onError)
    }

    private func resetRunningState() {
        lock.lock()
        isRunning = false
        onPCM = nil
        onLevel = nil
        onError = nil
        let observer = configurationObserver
        configurationObserver = nil
        lock.unlock()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
