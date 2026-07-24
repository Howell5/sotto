import AppKit
import ApplicationServices
import CoreGraphics
import SottoCore

@MainActor
final class FocusedTextTarget {
    fileprivate let element: AXUIElement
    fileprivate let processID: pid_t
    fileprivate let role: String?
    fileprivate let subrole: String?
    fileprivate let replacementSource: TextReplacementSource

    fileprivate init(
        element: AXUIElement,
        processID: pid_t,
        role: String?,
        subrole: String?,
        replacementSource: TextReplacementSource
    ) {
        self.element = element
        self.processID = processID
        self.role = role
        self.subrole = subrole
        self.replacementSource = replacementSource
    }
}

enum TextInsertionOutcome: Equatable {
    case inserted
    case copied(String)
}

@MainActor
final class TextInsertionService {
    private struct ResolvedFocus {
        let element: AXUIElement
        let processID: pid_t
    }

    private let maximumFallbackNodeCount = 5_000

    func captureFocusedTarget() -> FocusedTextTarget? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focus = resolveFocusedElement() else {
            return nil
        }
        return makeTarget(from: focus)
    }

    func insert(_ text: String, into target: FocusedTextTarget?) async -> TextInsertionOutcome {
        guard let capturedTarget = target else {
            copyOnly(text)
            return .copied(
                ClipboardRecoveryCopy.message(reason: "未识别到输入框")
            )
        }
        guard let target = resolveCurrentTarget(matching: capturedTarget) else {
            copyOnly(text)
            return .copied(
                ClipboardRecoveryCopy.message(reason: "输入焦点已变化")
            )
        }

        let capabilities = capabilities(for: target)
        switch InsertionStrategyResolver.resolve(
            capabilities,
            source: target.replacementSource
        ) {
        case .directValueReplacement:
            if replaceSelectedRange(text, in: target) {
                return .inserted
            }
            return await paste(text, target: target)
        case .pasteboard:
            return await paste(text, target: target)
        case let .copyOnly(reason):
            copyOnly(text)
            switch reason {
            case .secureField:
                return .copied(
                    ClipboardRecoveryCopy.message(
                        reason: "安全输入框不会自动写入"
                    )
                )
            case .focusChanged:
                return .copied(
                    ClipboardRecoveryCopy.message(reason: "输入焦点已变化")
                )
            }
        }
    }

    private func capabilities(for target: FocusedTextTarget) -> InsertionTargetCapabilities {
        let isSecure = target.subrole == "AXSecureTextField"
        let isNativeText = target.role == "AXTextField" || target.role == "AXTextArea"

        var valueSettable = DarwinBoolean(false)
        let valueStatus = AXUIElementIsAttributeSettable(
            target.element,
            "AXValue" as CFString,
            &valueSettable
        )
        let range = attribute("AXSelectedTextRange", from: target.element)

        return InsertionTargetCapabilities(
            isSameFocusedElement: true,
            isSecure: isSecure,
            isNativeTextControl: isNativeText,
            valueIsWritable: valueStatus == .success && valueSettable.boolValue,
            hasSelectedTextRange: range != nil
        )
    }

    private func replaceSelectedRange(_ text: String, in target: FocusedTextTarget) -> Bool {
        let element = target.element
        guard let value = attribute("AXValue", from: element) as? String,
              let rangeValue = attribute("AXSelectedTextRange", from: element),
              CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetType(rangeValue as! AXValue) == .cfRange
        else {
            return false
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selectedRange) else {
            return false
        }

        let nsRange = NSRange(location: selectedRange.location, length: selectedRange.length)
        let placeholderValue = attribute("AXPlaceholderValue", from: element) as? String
        guard let replacement = TextReplacementComposer.replacing(
            currentValue: value,
            placeholderValue: placeholderValue,
            selectedRange: nsRange,
            with: text,
            source: target.replacementSource
        ) else {
            return false
        }

        guard AXUIElementSetAttributeValue(
            element,
            "AXValue" as CFString,
            replacement as CFString
        ) == .success else {
            return false
        }

        var cursorRange = CFRange(
            location: selectedRange.location + (text as NSString).length,
            length: 0
        )
        if let newRange = AXValueCreate(.cfRange, &cursorRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                "AXSelectedTextRange" as CFString,
                newRange
            )
        }
        return true
    }

    private func paste(
        _ text: String,
        target: FocusedTextTarget
    ) async -> TextInsertionOutcome {
        guard let liveTarget = resolveCurrentTarget(matching: target) else {
            copyOnly(text)
            return .copied(
                ClipboardRecoveryCopy.message(reason: "输入焦点已变化")
            )
        }

        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            copyOnly(text)
            return .copied(
                ClipboardRecoveryCopy.message(reason: "需要自动粘贴权限")
            )
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let valueBefore = attribute("AXValue", from: liveTarget.element) as? String
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        guard postCommandV() else {
            return .copied(
                ClipboardRecoveryCopy.message(reason: "无法发送粘贴按键")
            )
        }

        try? await Task.sleep(for: .milliseconds(420))
        let valueAfter = attribute("AXValue", from: liveTarget.element) as? String
        if PasteDeliveryVerifier.didInsert(
            text: text,
            valueBefore: valueBefore,
            valueAfter: valueAfter
        ) {
            if pasteboard.changeCount == insertedChangeCount {
                snapshot.restore(to: pasteboard)
            }
            return .inserted
        }

        if pasteboard.string(forType: .string) != text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        return .copied(ClipboardRecoveryCopy.uncertainDeliveryMessage)
    }

    private func resolveCurrentTarget(
        matching capturedTarget: FocusedTextTarget
    ) -> FocusedTextTarget? {
        guard let focus = resolveFocusedElement(
            expectedProcessID: capturedTarget.processID
        ) else {
            return nil
        }
        let currentTarget = makeTarget(from: focus)

        guard TextTargetIdentityPolicy.isSameTarget(
            sameElement: CFEqual(
                capturedTarget.element,
                currentTarget.element
            )
        ) else {
            return nil
        }
        return currentTarget
    }

    private func resolveFocusedElement(
        expectedProcessID: pid_t? = nil
    ) -> ResolvedFocus? {
        let systemWide = AXUIElementCreateSystemWide()
        if let element = focusedElement(from: systemWide) {
            return resolvedFocus(for: element)
        }

        guard let processID = frontmostNormalWindowProcessID(),
              expectedProcessID.map({ $0 == processID }) ?? true
        else {
            return nil
        }

        let application = AXUIElementCreateApplication(processID)
        let focusedWindow = elementAttribute(
            "AXFocusedWindow",
            from: application
        )
        if let element = focusedElement(from: application) {
            return resolvedFocus(for: element)
        }
        guard let focusedWindow,
              let element = focusedTextDescendant(from: focusedWindow)
        else {
            return nil
        }
        return resolvedFocus(for: element)
    }

    private func resolvedFocus(
        for element: AXUIElement
    ) -> ResolvedFocus {
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        return ResolvedFocus(
            element: element,
            processID: processID
        )
    }

    private func makeTarget(from focus: ResolvedFocus) -> FocusedTextTarget {
        let bundleIdentifier = NSRunningApplication(
            processIdentifier: focus.processID
        )?.bundleIdentifier
        let domClasses = attribute(
            "AXDOMClassList",
            from: focus.element
        ) as? [String]
        let replacementSource: TextReplacementSource =
            bundleIdentifier == "com.openai.codex"
                && domClasses?.contains("ProseMirror") == true
                ? .codexProseMirror
                : .standard
        return FocusedTextTarget(
            element: focus.element,
            processID: focus.processID,
            role: attribute("AXRole", from: focus.element) as? String,
            subrole: attribute("AXSubrole", from: focus.element) as? String,
            replacementSource: replacementSource
        )
    }

    private func focusedTextDescendant(
        from root: AXUIElement
    ) -> AXUIElement? {
        var queue = [root]
        var index = 0

        while index < queue.count,
              index < maximumFallbackNodeCount {
            let element = queue[index]
            index += 1
            let role = attribute("AXRole", from: element) as? String
            let isFocused = attribute("AXFocused", from: element) as? Bool
                ?? false
            if FocusedTextCandidatePolicy.isEligible(
                role: role,
                isFocused: isFocused
            ) {
                return element
            }
            guard queue.count < maximumFallbackNodeCount,
                  let children = attribute(
                      "AXChildren",
                      from: element
                  ) as? [AXUIElement]
            else {
                continue
            }
            queue.append(
                contentsOf: children.prefix(
                    maximumFallbackNodeCount - queue.count
                )
            )
        }
        return nil
    }

    private func frontmostNormalWindowProcessID() -> pid_t? {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let candidates = rawWindows.compactMap { window -> WindowFocusCandidate? in
            guard let processID = window[
                kCGWindowOwnerPID as String
            ] as? pid_t,
            let layer = window[kCGWindowLayer as String] as? Int,
            let alpha = window[kCGWindowAlpha as String] as? Double,
            let boundsDictionary = window[
                kCGWindowBounds as String
            ] as? [String: Any],
            let bounds = CGRect(
                dictionaryRepresentation: boundsDictionary as CFDictionary
            ) else {
                return nil
            }
            return WindowFocusCandidate(
                processID: processID,
                layer: layer,
                alpha: alpha,
                width: bounds.width,
                height: bounds.height
            )
        }
        return WindowFocusCandidatePolicy.frontmostNormalProcessID(
            candidates,
            excluding: ProcessInfo.processInfo.processIdentifier
        )
    }

    private func elementAttribute(
        _ name: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        guard let value = attribute(name, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func focusedElement(from element: AXUIElement) -> AXUIElement? {
        guard let value = attribute("AXFocusedUIElement", from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    private func copyOnly(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x09,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x09,
                keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(
                values: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            )
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
