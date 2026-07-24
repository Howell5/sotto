import AppKit
import SwiftUI
import SottoCore

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class OverlayPanelController: AnyObject {
    private let panel: NonActivatingPanel
    private let hostingView: FirstMouseHostingView<OverlayView>
    private let model: AppModel
    private var visiblePresentation: DictationOverlayPresentation?
    private var presentationGeneration = 0
    private var insertionDismissalGeneration: Int?
    private var readyInsertionDismissalGeneration: Int?

    init(model: AppModel) {
        self.model = model
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 232, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = FirstMouseHostingView(
            rootView: OverlayView(
                model: model,
                phase: .idle
            )
        )
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
    }

    func render(phase: DictationPhase) {
        if phase == .inserting {
            dismissForInsertion()
            return
        }

        guard let presentation = DictationOverlayPresentation.resolve(phase) else {
            presentationGeneration += 1
            visiblePresentation = nil
            insertionDismissalGeneration = nil
            readyInsertionDismissalGeneration = nil
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        panel.ignoresMouseEvents = presentation != .listening
        let needsPresentationTransition =
            presentation != visiblePresentation || !panel.isVisible
        if needsPresentationTransition {
            panel.alphaValue = 0
        }
        hostingView.rootView = OverlayView(
            model: model,
            phase: phase
        )
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        guard needsPresentationTransition else {
            return
        }

        presentationGeneration += 1
        insertionDismissalGeneration = nil
        readyInsertionDismissalGeneration = nil
        visiblePresentation = presentation
        let size = panelSize(for: presentation)
        panel.setContentSize(size)
        position(size: size)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0.12
                : 0.18
            panel.animator().alphaValue = 1
        }
    }

    func waitUntilDismissedForInsertion() async -> Bool {
        guard let expectedGeneration = insertionDismissalGeneration else {
            return false
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(750))

        while !Task.isCancelled {
            switch OverlayDismissalReadinessPolicy.resolve(
                expectedGeneration: expectedGeneration,
                currentGeneration: presentationGeneration,
                readyGeneration: readyInsertionDismissalGeneration,
                isPanelVisible: panel.isVisible,
                hasTimedOut: clock.now >= deadline
            ) {
            case .ready:
                return true
            case .unavailable:
                return false
            case .waiting:
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func dismissForInsertion() {
        presentationGeneration += 1
        let generation = presentationGeneration
        visiblePresentation = nil
        insertionDismissalGeneration = generation
        readyInsertionDismissalGeneration = nil
        panel.ignoresMouseEvents = true

        guard panel.isVisible else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            readyInsertionDismissalGeneration = generation
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0
                : 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      self.insertionDismissalGeneration == generation,
                      self.visiblePresentation == nil
                else { return }
                self.panel.orderOut(nil)
                self.readyInsertionDismissalGeneration = generation
            }
        }
    }

    private func panelSize(
        for presentation: DictationOverlayPresentation
    ) -> NSSize {
        switch presentation {
        case .listening: NSSize(width: 280, height: 52)
        case .thinking: NSSize(width: 164, height: 44)
        case .cancelled: NSSize(width: 124, height: 40)
        case .error: NSSize(width: 380, height: 56)
        }
    }

    private func position(size: NSSize) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.minY + 48
            )
        )
    }
}

private struct OverlayView: View {
    @ObservedObject var model: AppModel
    let phase: DictationPhase

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x1D1E1C))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .foregroundStyle(Color(hex: 0xF4F3EF))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .listening:
            Circle()
                .fill(Color(hex: 0x9EC39A))
                .frame(width: 8, height: 8)
            Text(DictationOverlayCopy.listening)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 2)
            LevelMeter(level: model.audioLevel)
            Button {
                model.cancelDictation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel("取消听写")
            .help("取消，不转写")

            Button {
                model.finishDictation()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color(hex: 0x9EC39A))
                    .foregroundStyle(Color(hex: 0x1D1E1C))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel("完成并转写")
            .help("完成并写入原输入框")
        case .processing, .polishing:
            ProgressView()
                .controlSize(.small)
                .tint(Color(hex: 0xD8B46B))
            Text(DictationOverlayCopy.thinking)
                .font(.system(size: 13, weight: .semibold))
        case .inserting:
            EmptyView()
        case .success:
            EmptyView()
        case .cancelled:
            Text(DictationOverlayCopy.cancelled)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0xB6B7B1))
        case let .error(message, _):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hex: 0xE39288))
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
        }
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(Color(hex: 0x9EC39A))
                    .frame(
                        width: 2,
                        height: max(4, 5 + normalizedLevel(for: index) * 13)
                    )
            }
        }
        .frame(width: 30, height: 20)
        .accessibilityHidden(true)
    }

    private func normalizedLevel(for index: Int) -> Double {
        let shape = 1 - abs(Double(index - 3)) / 4
        return min(1, max(0, level)) * shape
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
