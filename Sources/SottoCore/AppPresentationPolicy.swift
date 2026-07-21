public enum AppActivationMode: Equatable, Sendable {
    case regular
    case accessory
}

public enum AppPresentationPolicy {
    public static let activationMode: AppActivationMode = .regular
    public static let showsSettingsOnLaunch = true
    public static let showsSettingsOnReopen = true
}
