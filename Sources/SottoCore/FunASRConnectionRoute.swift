import Foundation

public enum FunASRServiceRegion: Equatable, Sendable {
    case mainlandChina
    case singapore

    fileprivate var sharedWebSocketHost: String {
        switch self {
        case .mainlandChina:
            "dashscope.aliyuncs.com"
        case .singapore:
            "dashscope-intl.aliyuncs.com"
        }
    }
}

public struct FunASRConnectionRoute: Equatable, Sendable {
    public let endpoint: URL
    public let workspaceHeaderValue: String

    public static func resolve(
        region: FunASRServiceRegion,
        workspaceInput: String
    ) -> FunASRConnectionRoute? {
        guard let workspaceID = BailianWorkspaceInput.normalizedID(from: workspaceInput) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = region.sharedWebSocketHost
        components.path = "/api-ws/v1/inference/"
        guard let endpoint = components.url else { return nil }

        return FunASRConnectionRoute(
            endpoint: endpoint,
            workspaceHeaderValue: workspaceID
        )
    }
}
