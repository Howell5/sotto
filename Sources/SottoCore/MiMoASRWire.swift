import Foundation

public enum MiMoSSEEvent: Equatable, Sendable {
    case delta(String)
    case done
    case ignored
}

public enum MiMoASRWire {
    public static func makeRequest(
        wav: Data,
        language: ASRLanguage,
        streamResponse: Bool
    ) throws -> Data {
        let dataURL = "data:audio/wav;base64,\(wav.base64EncodedString())"
        let request = Request(
            messages: [
                .init(
                    content: [
                        .init(inputAudio: .init(data: dataURL))
                    ]
                )
            ],
            asrOptions: .init(language: language.rawValue),
            stream: streamResponse
        )
        return try JSONEncoder().encode(request)
    }

    public static func decodeSSELine(_ line: String) throws -> MiMoSSEEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            return .ignored
        }

        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return .done
        }

        guard let data = payload.data(using: .utf8) else {
            return .ignored
        }
        let chunk = try JSONDecoder().decode(StreamChunk.self, from: data)
        if let content = chunk.choices.first?.delta?.content, !content.isEmpty {
            return .delta(content)
        }
        if chunk.choices.first?.finishReason == "stop" {
            return .done
        }
        return .ignored
    }

    public static func failure(forHTTPStatus statusCode: Int, message: String) -> ASRFailure {
        switch statusCode {
        case 400:
            return .init(kind: .badInput, message: message, retryable: false)
        case 401:
            return .init(kind: .unauthorized, message: message, retryable: false)
        case 402:
            return .init(kind: .insufficientBalance, message: message, retryable: false)
        case 421:
            return .init(kind: .contentFiltered, message: message, retryable: false)
        case 429:
            return .init(kind: .rateLimited, message: message, retryable: true)
        case 500, 503:
            return .init(kind: .provider, message: message, retryable: true)
        default:
            return .init(kind: .provider, message: message, retryable: false)
        }
    }
}

private struct Request: Encodable {
    struct Message: Encodable {
        struct Content: Encodable {
            struct InputAudio: Encodable {
                let data: String
            }

            let type = "input_audio"
            let inputAudio: InputAudio

            enum CodingKeys: String, CodingKey {
                case type
                case inputAudio = "input_audio"
            }
        }

        let role = "user"
        let content: [Content]
    }

    struct ASROptions: Encodable {
        let language: String
    }

    let model = "mimo-v2.5-asr"
    let messages: [Message]
    let asrOptions: ASROptions
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case asrOptions = "asr_options"
        case stream
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
}
