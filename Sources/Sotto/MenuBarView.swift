import AppKit
import SwiftUI
import SottoCore

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Text(statusLine)
            .foregroundStyle(.secondary)

        Divider()

        Button(actionTitle) {
            if model.phase == .listening {
                model.finishDictation()
            } else {
                model.toggleDictation()
            }
        }
        .disabled(primaryActionDisabled)

        if model.phase == .listening {
            Button("Cancel Dictation", role: .cancel) {
                model.cancelDictation()
            }
        }

        Button("Copy Last Result") {
            model.copyLastResult()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(model.lastResult == nil)

        Divider()

        Button("Open Settings…") {
            model.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit Sotto") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var statusLine: String {
        switch model.phase {
        case .idle: "Ready · \(settings.provider.title)"
        case .listening: DictationOverlayCopy.listening
        case .processing, .polishing: DictationOverlayCopy.thinking
        case .inserting: DictationOverlayCopy.writing
        case .success: "Ready"
        case .cancelled: "Cancelled"
        case let .error(message, _): message
        }
    }

    private var actionTitle: String {
        switch model.phase {
        case .idle: "Start Listening"
        case .listening: "Finish Dictation"
        case .processing, .polishing: DictationOverlayCopy.thinking
        case .inserting: DictationOverlayCopy.writing
        case .success: "Start Listening"
        case .cancelled: "Cancelled"
        case .error: "Unavailable"
        }
    }

    private var primaryActionDisabled: Bool {
        switch model.phase {
        case .idle:
            !model.canStart
        case .listening:
            false
        case .processing, .polishing, .inserting, .success, .cancelled, .error:
            true
        }
    }
}
