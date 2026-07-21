import Foundation

public enum FunServerEvent: Equatable, Sendable {
    case started
    case transcript(
        sentenceID: Int,
        text: String,
        isFinal: Bool,
        billedSeconds: Double?
    )
    case heartbeat
    case finished
    case failed(code: String?, message: String)
    case unknown(String)
}

public enum FunASRWireError: Error, Equatable, Sendable {
    case malformedResult
}

public enum FunASRWire {
    public static func makeRunTask(
        taskID: String,
        configuration: ASRConfiguration
    ) throws -> Data {
        try JSONEncoder().encode(
            RunTask(
                header: .init(taskID: taskID),
                payload: .init(
                    parameters: .init(
                        sampleRate: configuration.sampleRate,
                        maxSentenceSilence: configuration.maxSentenceSilenceMilliseconds
                    )
                )
            )
        )
    }

    public static func makeFinishTask(taskID: String) throws -> Data {
        try JSONEncoder().encode(FinishTask(header: .init(taskID: taskID)))
    }

    public static func decodeServerEvent(_ data: Data) throws -> FunServerEvent {
        let envelope = try JSONDecoder().decode(ServerEnvelope.self, from: data)

        switch envelope.header.event {
        case "task-started":
            return .started
        case "task-finished":
            return .finished
        case "task-failed":
            return .failed(
                code: envelope.header.errorCode,
                message: envelope.header.errorMessage ?? "Fun-ASR request failed"
            )
        case "result-generated":
            guard let sentence = envelope.payload?.output?.sentence else {
                throw FunASRWireError.malformedResult
            }
            if sentence.heartbeat == true {
                return .heartbeat
            }
            guard let text = sentence.text, let sentenceID = sentence.sentenceID else {
                throw FunASRWireError.malformedResult
            }
            return .transcript(
                sentenceID: sentenceID,
                text: text,
                isFinal: sentence.sentenceEnd ?? false,
                billedSeconds: envelope.payload?.usage?.duration
            )
        default:
            return .unknown(envelope.header.event)
        }
    }
}

public struct FunTranscriptAssembler: Sendable {
    private var finalSegments: [Int: String] = [:]
    private var partialSegments: [Int: String] = [:]
    public private(set) var billedSeconds: Double?

    public init() {}

    @discardableResult
    public mutating func apply(_ event: FunServerEvent) -> String {
        if case let .transcript(sentenceID, text, isFinal, billedSeconds) = event {
            if isFinal {
                finalSegments[sentenceID] = text
                partialSegments.removeValue(forKey: sentenceID)
                if let billedSeconds {
                    self.billedSeconds = billedSeconds
                }
            } else {
                partialSegments[sentenceID] = text
            }
        }

        let sentenceIDs = Set(finalSegments.keys).union(partialSegments.keys).sorted()
        return sentenceIDs.map { sentenceID in
            finalSegments[sentenceID] ?? partialSegments[sentenceID] ?? ""
        }.joined()
    }
}

private struct RunTask: Encodable {
    struct Header: Encodable {
        let action = "run-task"
        let taskID: String
        let streaming = "duplex"

        enum CodingKeys: String, CodingKey {
            case action
            case taskID = "task_id"
            case streaming
        }
    }

    struct Payload: Encodable {
        struct Parameters: Encodable {
            let format = "pcm"
            let sampleRate: Int
            let semanticPunctuationEnabled = false
            let maxSentenceSilence: Int

            enum CodingKeys: String, CodingKey {
                case format
                case sampleRate = "sample_rate"
                case semanticPunctuationEnabled = "semantic_punctuation_enabled"
                case maxSentenceSilence = "max_sentence_silence"
            }
        }

        let taskGroup = "audio"
        let task = "asr"
        let function = "recognition"
        let model = "fun-asr-realtime"
        let parameters: Parameters
        let input: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case taskGroup = "task_group"
            case task
            case function
            case model
            case parameters
            case input
        }
    }

    let header: Header
    let payload: Payload
}

private struct FinishTask: Encodable {
    struct Header: Encodable {
        let action = "finish-task"
        let taskID: String
        let streaming = "duplex"

        enum CodingKeys: String, CodingKey {
            case action
            case taskID = "task_id"
            case streaming
        }
    }

    struct Payload: Encodable {
        let input: [String: String] = [:]
    }

    let header: Header
    let payload = Payload()
}

private struct ServerEnvelope: Decodable {
    struct Header: Decodable {
        let event: String
        let errorCode: String?
        let errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case event
            case errorCode = "error_code"
            case errorMessage = "error_message"
        }
    }

    struct Payload: Decodable {
        struct Output: Decodable {
            struct Sentence: Decodable {
                let text: String?
                let heartbeat: Bool?
                let sentenceEnd: Bool?
                let sentenceID: Int?

                enum CodingKeys: String, CodingKey {
                    case text
                    case heartbeat
                    case sentenceEnd = "sentence_end"
                    case sentenceID = "sentence_id"
                }
            }

            let sentence: Sentence?
        }

        struct Usage: Decodable {
            let duration: Double?
        }

        let output: Output?
        let usage: Usage?
    }

    let header: Header
    let payload: Payload?
}
