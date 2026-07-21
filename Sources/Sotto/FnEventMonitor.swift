import Carbon.HIToolbox
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import SottoCore

private func sottoEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<FnEventMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    monitor.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class FnEventMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var interpreter = FnGestureInterpreter()
    private var pendingActivation: DispatchWorkItem?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onToggle: @MainActor @Sendable () -> Void
    private let onEscape: @MainActor @Sendable () -> Void

    init(
        onToggle: @escaping @MainActor @Sendable () -> Void,
        onEscape: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onToggle = onToggle
        self.onEscape = onEscape
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() || CGPreflightListenEventAccess() else {
            // A previously valid tap becomes stale after the user revokes
            // permission. Clear it now so re-grant can rebuild cleanly.
            stop()
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: sottoEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        lock.lock()
        pendingActivation?.cancel()
        pendingActivation = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        interpreter = FnGestureInterpreter()
        lock.unlock()
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            pendingActivation?.cancel()
            pendingActivation = nil
            interpreter = FnGestureInterpreter()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Int64(kVK_Escape) {
                Task { @MainActor [onEscape] in onEscape() }
            }
            apply(.nonModifierKeyPressed)
            return
        }

        guard type == .flagsChanged else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_Function) else { return }

        let flags = event.flags
        let fnIsDown = flags.contains(.maskSecondaryFn)
        let otherModifiers: CGEventFlags = [
            .maskCommand,
            .maskAlternate,
            .maskControl,
            .maskShift
        ]
        apply(
            .fnChanged(
                isDown: fnIsDown,
                hasOtherModifiers: !flags.intersection(otherModifiers).isEmpty
            )
        )
    }

    private func apply(_ event: FnGestureEvent) {
        lock.lock()
        let action = interpreter.handle(event)
        lock.unlock()
        perform(action)
    }

    private func perform(_ action: FnGestureAction) {
        switch action {
        case .none:
            break
        case let .scheduleActivation(afterMilliseconds):
            let workItem = DispatchWorkItem { [weak self] in
                self?.apply(.activationDeadlineReached)
            }
            lock.lock()
            pendingActivation?.cancel()
            pendingActivation = workItem
            lock.unlock()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(afterMilliseconds),
                execute: workItem
            )
        case .cancelPendingActivation:
            lock.lock()
            pendingActivation?.cancel()
            pendingActivation = nil
            lock.unlock()
        case .activateToggle:
            lock.lock()
            pendingActivation?.cancel()
            pendingActivation = nil
            lock.unlock()
            Task { @MainActor [onToggle] in onToggle() }
        }
    }
}
