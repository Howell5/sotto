import Foundation

public enum FunASRFailureMapper {
    public static func providerFailure(code: String?, message: String) -> ASRFailure {
        let searchable = "\(code ?? "") \(message)".lowercased()
        let compact = searchable.filter { $0.isLetter || $0.isNumber }

        if compact.contains("invalidapikey")
            || compact.contains("workspaceaccessdenied")
            || compact.contains("modelaccessdenied")
            || searchable.contains("unauthor")
            || searchable.contains("not authorized") {
            return ASRFailure(
                kind: .unauthorized,
                providerCode: code,
                message: message,
                retryable: false
            )
        }

        if searchable.contains("throttl")
            || (searchable.contains("rate") && searchable.contains("limit")) {
            return ASRFailure(
                kind: .rateLimited,
                providerCode: code,
                message: message,
                retryable: true
            )
        }

        if searchable.contains("arrearage") || searchable.contains("balance") {
            return ASRFailure(
                kind: .insufficientBalance,
                providerCode: code,
                message: message,
                retryable: false
            )
        }

        if searchable.contains("audio")
            || searchable.contains("decoder")
            || searchable.contains("sample rate") {
            return ASRFailure(
                kind: .badInput,
                providerCode: code,
                message: message,
                retryable: false
            )
        }

        return ASRFailure(
            kind: .provider,
            providerCode: code,
            message: message,
            retryable: false
        )
    }
}
