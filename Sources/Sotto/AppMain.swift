import AppKit
import SottoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var overlayController: OverlayPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var fnEventMonitor: FnEventMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch AppPresentationPolicy.activationMode {
        case .regular:
            NSApp.setActivationPolicy(.regular)
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        }
        let overlayController = OverlayPanelController(model: model)
        self.overlayController = overlayController
        model.attachOverlay(overlayController)

        let settingsWindowController = SettingsWindowController(model: model)
        self.settingsWindowController = settingsWindowController
        model.attachSettingsWindow(settingsWindowController)
        model.bootstrap()

        let fnEventMonitor = FnEventMonitor(
            onToggle: { [weak model] in
                model?.toggleDictation()
            },
            onEscape: { [weak model] in
                model?.cancelDictation()
            }
        )
        self.fnEventMonitor = fnEventMonitor
        synchronizeFnEventMonitor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        if AppPresentationPolicy.showsSettingsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.model.openSettings()
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if AppPresentationPolicy.showsSettingsOnReopen {
            model.openSettings()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnEventMonitor?.stop()
        model.shutdown()
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func applicationBecameActive() {
        model.permissions.refresh()
        if model.permissions.consumeSettingsRestorationRequest() {
            model.restoreSettingsAfterPermissionPrompt()
        }
        synchronizeFnEventMonitor()
    }

    private func synchronizeFnEventMonitor() {
        guard let fnEventMonitor else { return }
        fnEventMonitor.stop()
        if model.permissions.canMonitorFn {
            _ = fnEventMonitor.start()
        }
    }
}

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.settings)
        } label: {
            Image(nsImage: menuBarImage)
                .accessibilityLabel("Sotto")
        }
        .menuBarExtraStyle(.menu)

    }

    private var menuBarSymbol: String {
        switch appDelegate.model.phase {
        case .listening: "waveform.circle.fill"
        case .processing, .polishing, .inserting: "ellipsis.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        default: "waveform"
        }
    }

    private var menuBarImage: NSImage {
        if case .idle = appDelegate.model.phase,
           let url = Bundle.main.url(
               forResource: "SottoMenuBarTemplate",
               withExtension: "png"
           ), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        return NSImage(
            systemSymbolName: menuBarSymbol,
            accessibilityDescription: "Sotto"
        ) ?? NSImage()
    }
}
