import Foundation
import SottoCore

/// Keeps per-frame provider traffic away from MainActor. UI coordination waits
/// on this actor, while audio delivery and finish ordering remain serialized.
actor AudioTransportRunner {
    func run(
        session: any ASRSession,
        configuration: ASRConfiguration,
        stream: AsyncStream<Data>
    ) async throws {
        try await session.start(configuration: configuration)
        for await chunk in stream {
            try Task.checkCancellation()
            try await session.sendPCM16(chunk)
        }
        try Task.checkCancellation()
        try await session.finish()
    }
}
