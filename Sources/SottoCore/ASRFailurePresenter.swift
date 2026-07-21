import Foundation

public enum ASRFailurePresenter {
    public static func userMessage(
        for failure: ASRFailure,
        serviceName: String
    ) -> String {
        if failure.kind == .unauthorized {
            return "\(serviceName)鉴权失败，请检查 API Key、API Host 和区域"
        }
        return failure.message
    }

    public static func diagnosticSummary(for failure: ASRFailure) -> String {
        let message = failure.message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = failure.providerCode?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !code.isEmpty else {
            return message
        }
        return message.isEmpty ? code : "\(code) · \(message)"
    }
}
