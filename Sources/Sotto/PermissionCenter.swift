import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import CoreGraphics
import Security
import SottoCore

@MainActor
final class PermissionCenter: ObservableObject {
    typealias State = AppPermissionState
    typealias Kind = AppPermissionKind

    enum FlowResult: Equatable {
        case completedInApp
        case requestDispatched
        case openedSystemSettings
        case noAction
    }

    @Published private(set) var microphone: State = .notDetermined
    @Published private(set) var accessibility: State = .notDetermined
    @Published private(set) var inputMonitoring: State = .notDetermined
    @Published private(set) var inFlight: Set<Kind> = []
    private var requestedSystemPermissions: Set<Kind> = []
    private var needsSettingsRestoration = false

    init() {
        refresh()
    }

    func state(for kind: Kind) -> State {
        switch kind {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }

    func action(for kind: Kind) -> AppPermissionAction {
        PermissionPolicy.action(for: kind, state: state(for: kind))
    }

    func isRequesting(_ kind: Kind) -> Bool {
        inFlight.contains(kind)
    }

    var canMonitorFn: Bool {
        PermissionPolicy.canMonitorFn(
            accessibility: accessibility,
            inputMonitoring: inputMonitoring
        )
    }

    func refresh() {
        if hasValidMicrophoneConfiguration() {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                microphone = .granted
            case .denied:
                microphone = .denied
            case .restricted:
                microphone = .restricted
            case .notDetermined:
                microphone = .notDetermined
            @unknown default:
                microphone = .restricted
            }
        } else {
            // Requesting capture without both of these values lets TCC
            // terminate the process. Never call requestAccess in this state.
            microphone = .misconfigured
        }

        accessibility = AXIsProcessTrusted()
            ? .granted
            : PermissionPolicy.unresolvedSystemState(
                requestAttempted: requestedSystemPermissions.contains(.accessibility)
            )
        inputMonitoring = CGPreflightListenEventAccess()
            ? .granted
            : PermissionPolicy.unresolvedSystemState(
                requestAttempted: requestedSystemPermissions.contains(.inputMonitoring)
            )
    }

    @discardableResult
    func perform(_ kind: Kind) async -> FlowResult {
        guard !inFlight.contains(kind) else { return .noAction }

        switch action(for: kind) {
        case .none, .unavailable:
            return .noAction

        case .openSystemSettings:
            openPrivacySettings(for: kind)
            return .openedSystemSettings

        case .request:
            inFlight.insert(kind)
            defer { inFlight.remove(kind) }
            needsSettingsRestoration = true

            switch kind {
            case .microphone:
                guard microphone == .notDetermined else { return .noAction }
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refresh()
                return .completedInApp

            case .accessibility:
                guard accessibility == .notDetermined else { return .noAction }
                requestedSystemPermissions.insert(kind)
                let options = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                refresh()
                return .requestDispatched

            case .inputMonitoring:
                // Accessibility is already required for text insertion and
                // also permits a listen-only event tap. Keep this legacy path
                // non-blocking if invoked by an older view.
                openPrivacySettings(for: kind)
                return .openedSystemSettings
            }
        }
    }

    func consumeSettingsRestorationRequest() -> Bool {
        guard needsSettingsRestoration else { return false }
        needsSettingsRestoration = false
        return true
    }

    func completeSettingsRestoration() {
        needsSettingsRestoration = false
    }

    func openPrivacySettings(for kind: Kind) {
        let anchor: String
        switch kind {
        case .microphone:
            anchor = "Privacy_Microphone"
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        }

        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func hasValidMicrophoneConfiguration() -> Bool {
        guard let usageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSMicrophoneUsageDescription"
        ) as? String,
        !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let task = SecTaskCreateFromSelf(nil),
        let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.device.audio-input" as CFString,
            nil
        ) as? Bool
        else {
            return false
        }
        return entitlement
    }
}

extension AppPermissionState {
    var title: String {
        switch self {
        case .granted: "已允许"
        case .denied: "未允许"
        case .notDetermined: "尚未请求"
        case .restricted: "受系统限制"
        case .misconfigured: "开发构建不完整"
        }
    }
}
