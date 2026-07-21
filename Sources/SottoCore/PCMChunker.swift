import Foundation

public struct PCMChunker: Sendable {
    private let frameByteCount: Int
    private var buffer = Data()

    public init(frameByteCount: Int) {
        self.frameByteCount = frameByteCount
    }

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= frameByteCount {
            frames.append(buffer.prefix(frameByteCount))
            buffer.removeFirst(frameByteCount)
        }

        return frames
    }

    public mutating func drain() -> Data {
        let remainder = buffer
        buffer = Data()
        return remainder
    }
}
