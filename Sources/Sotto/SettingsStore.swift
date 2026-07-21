import Foundation
import SottoCore

enum SpeechProviderKind: String, CaseIterable, Identifiable, Sendable {
    case funASR = "fun-asr"
    case miMo = "mimo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .funASR: "Fun-ASR Realtime"
        case .miMo: "MiMo-V2.5-ASR"
        }
    }

    var subtitle: String {
        switch self {
        case .funASR: "中文实时 · 推荐"
        case .miMo: "中英混说 · 松开后整段提交"
        }
    }
}

enum FunRegion: String, CaseIterable, Identifiable, Sendable {
    case mainlandChina = "mainland"
    case international = "international"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainlandChina: "中国大陆（北京）"
        case .international: "国际（新加坡）"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let provider = "speechProvider"
        static let funRegion = "funRegion"
        static let funWorkspaceID = "funWorkspaceID"
        static let language = "asrLanguage"
        static let cleanupEnabled = "cleanupEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let onboardingComplete = "onboardingComplete"
    }

    private let defaults: UserDefaults

    @Published var provider: SpeechProviderKind {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }

    @Published var funRegion: FunRegion {
        didSet { defaults.set(funRegion.rawValue, forKey: Key.funRegion) }
    }

    @Published var funWorkspaceID: String {
        didSet { defaults.set(funWorkspaceID, forKey: Key.funWorkspaceID) }
    }

    @Published var languageRawValue: String {
        didSet { defaults.set(languageRawValue, forKey: Key.language) }
    }

    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = .funASR
        funRegion = FunRegion(
            rawValue: defaults.string(forKey: Key.funRegion) ?? ""
        ) ?? .mainlandChina
        funWorkspaceID = defaults.string(forKey: Key.funWorkspaceID) ?? ""
        languageRawValue = defaults.string(forKey: Key.language) ?? "auto"
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled) == nil
            ? BailianCleanupPolicy.enabledByDefault
            : defaults.bool(forKey: Key.cleanupEnabled)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        onboardingComplete = defaults.bool(forKey: Key.onboardingComplete)
        defaults.set(SpeechProviderKind.funASR.rawValue, forKey: Key.provider)
    }
}
