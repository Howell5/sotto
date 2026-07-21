import Foundation

public enum TranscriptRejectionReason: Equatable, Sendable {
    case emptyOutput
    case protectedTokenChanged
    case excessiveExpansion
}

public enum TranscriptDecision: Equatable, Sendable {
    case usePolished(String)
    case useOriginal(String, reason: TranscriptRejectionReason)
}

public struct TranscriptGuard: Sendable {
    private struct ProtectedToken: Equatable {
        let value: String
        let range: NSRange
    }

    public init() {}

    public func evaluate(raw: String, polished: String) -> TranscriptDecision {
        let candidate = polished.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidate.isEmpty else {
            return .useOriginal(raw, reason: .emptyOutput)
        }

        let maximumLength = max(raw.count * 3, raw.count + 24)
        guard candidate.count <= maximumLength else {
            return .useOriginal(raw, reason: .excessiveExpansion)
        }

        guard protectedTokensAreCompatible(raw: raw, candidate: candidate) else {
            return .useOriginal(raw, reason: .protectedTokenChanged)
        }

        return .usePolished(candidate)
    }

    private func protectedTokensAreCompatible(raw: String, candidate: String) -> Bool {
        let rawTokens = protectedTokens(in: raw)
        let candidateValues = collapsedValues(protectedTokens(in: candidate))
        let supersededIndexes = explicitlySupersededTokenIndexes(
            in: raw,
            tokens: rawTokens
        )
        let expectedValues = collapsedValues(
            rawTokens.enumerated().compactMap { index, token in
                supersededIndexes.contains(index) ? nil : token
            }
        )

        return candidateValues == expectedValues
    }

    private func protectedTokens(in text: String) -> [ProtectedToken] {
        let pattern = #"(?i)(?:\b(?:https?://|www\.)[^\s<>()]+|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|(?<![A-Z0-9_])(?:[$¥€£]\s*)?[+-]?\d[\d,]*(?:[.:/-]\d+)*(?:\s*%)?|[零〇一二两三四五六七八九十百千万亿]+(?=(?:点|时|分|秒|年|月|日|号|个|人|元|块|%)))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else {
                return nil
            }
            return ProtectedToken(
                value: normalizeProtectedToken(String(text[swiftRange])),
                range: match.range
            )
        }
    }

    private func explicitlySupersededTokenIndexes(
        in text: String,
        tokens: [ProtectedToken]
    ) -> Set<Int> {
        guard tokens.count >= 2 else { return [] }

        let pattern = #"(?i)(?:哦|噢|啊)?(?:不(?:对|是)?|错了|说错了)|改成|改为|更正为|应该是|\b(?:no|actually|rather|i\s+mean|correction)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let markers = regex.matches(in: text, range: fullRange)
        var superseded = Set<Int>()

        for marker in markers {
            guard tokens.contains(where: { $0.range.location >= NSMaxRange(marker.range) }) else {
                continue
            }
            guard let previousIndex = tokens.indices.last(where: {
                NSMaxRange(tokens[$0].range) <= marker.range.location
            }) else {
                continue
            }
            superseded.insert(previousIndex)
        }

        return superseded
    }

    private func collapsedValues(_ tokens: [ProtectedToken]) -> [String] {
        tokens.reduce(into: []) { values, token in
            if values.last != token.value {
                values.append(token.value)
            }
        }
    }

    private func normalizeProtectedToken(_ token: String) -> String {
        token.trimmingCharacters(
            in: CharacterSet(charactersIn: ".,!?;:，。！？；：)]}>\"'")
        )
    }
}
