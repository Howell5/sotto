import Foundation

public enum BailianWorkspaceInput {
    private static let hostSuffixes = [
        ".cn-beijing.maas.aliyuncs.com",
        ".ap-southeast-1.maas.aliyuncs.com"
    ]

    public static func normalizedID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let host: String
        if trimmed.contains("://") {
            guard let parsedHost = URLComponents(string: trimmed)?.host else { return nil }
            host = parsedHost.lowercased()
        } else if trimmed.contains("/") || trimmed.contains(".") {
            guard let parsedHost = URLComponents(string: "https://\(trimmed)")?.host else {
                return nil
            }
            host = parsedHost.lowercased()
        } else {
            host = trimmed.lowercased()
        }

        for suffix in hostSuffixes where host.hasSuffix(suffix) {
            let workspaceID = String(host.dropLast(suffix.count))
            return isValidBareID(workspaceID) ? workspaceID : nil
        }
        return isValidBareID(host) ? host : nil
    }

    private static func isValidBareID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }
}
