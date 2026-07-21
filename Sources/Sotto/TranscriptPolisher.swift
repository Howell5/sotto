import Foundation
import SottoCore

enum TranscriptPolisherError: LocalizedError {
    case invalidEndpoint
    case badResponse
    case provider(statusCode: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "整理服务 Endpoint 无效"
        case .badResponse:
            "整理服务返回了无法识别的响应"
        case let .provider(statusCode, message):
            "整理服务错误（\(statusCode)）：\(message)"
        case .emptyResponse:
            "整理服务没有返回文字"
        }
    }
}

actor TranscriptPolisher {
    private struct ResponseBody: Decodable, Sendable {
        struct Choice: Decodable, Sendable {
            struct Message: Decodable, Sendable {
                let content: String
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct ErrorBody: Decodable, Sendable {
        struct Detail: Decodable, Sendable {
            let message: String?
        }

        let error: Detail?
    }

    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession

    init(
        route: BailianCleanupRoute,
        apiKey: String,
        session: URLSession = .shared
    ) {
        endpoint = route.endpoint
        self.apiKey = apiKey
        self.session = session
    }

    func polish(_ rawTranscript: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        request.httpBody = try BailianCleanupWire.makeRequest(
            rawTranscript: rawTranscript
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptPolisherError.badResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let providerMessage = (try? JSONDecoder().decode(ErrorBody.self, from: data))?
                .error?.message ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw TranscriptPolisherError.provider(
                statusCode: httpResponse.statusCode,
                message: providerMessage
            )
        }

        let result = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let text = result.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            throw TranscriptPolisherError.emptyResponse
        }
        return text
    }

}
