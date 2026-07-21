public enum FunASRConfigurationPolicy {
    public static func isReady(hasAPIKey: Bool, workspaceInput: String) -> Bool {
        hasAPIKey && BailianWorkspaceInput.normalizedID(from: workspaceInput) != nil
    }
}
