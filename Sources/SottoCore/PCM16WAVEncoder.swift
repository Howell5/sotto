import Foundation

public struct PCM16WAVEncoder: Sendable {
    public init() {}

    public func encode(
        _ pcm: Data,
        sampleRate: Int,
        channelCount: Int
    ) throws -> Data {
        var wav = Data()
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(channelCount))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(UInt32(sampleRate * channelCount * 2))
        wav.appendLittleEndian(UInt16(channelCount * 2))
        wav.appendLittleEndian(UInt16(16))
        wav.appendASCII("data")
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii) ?? Data())
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        for byteIndex in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: value >> T(byteIndex * 8)))
        }
    }
}
