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
    func captureFocusedTarget() -> FocusedTextTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        guard let element = focusedElement(from: systemWide) else {
            return nil
        }

        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        let bundleIdentifier = NSRunningApplication(
            processIdentifier: processID
        )?.bundleIdentifier
        let domClasses = attribute("AXDOMClassList", from: element) as? [String]
        let replacementSource: TextReplacementSource = bundleIdentifier == "com.openai.codex"
            && domClasses?.contains("ProseMirror") == true
            ? .codexProseMirror
            : .standard
        return FocusedTextTarget(
            element: element,
            processID: processID,
            role: attribute("AXRole", from: element) as? String,
            subrole: attribute("AXSubrole", from: element) as? String,
            replacementSource: replacementSource
        )
    }

    func insert(_ text: String, into target: FocusedTextTarget?) async -> TextInsertionOutcome {
        guard let target else {
            copyOnly(text)
            return .copied("未找到输入框，结果已复制")
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
                return .copied("安全输入框不会自动写入，结果已复制")
            case .focusChanged:
                return .copied("输入焦点已变化，结果已复制")
            }
        }
    }

    private func capabilities(for target: FocusedTextTarget) -> InsertionTargetCapabilities {
        let current = currentFocusedElement()
        let sameElement = current.map { CFEqual($0, target.element) } ?? false
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
            isSameFocusedElement: sameElement,
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
        guard currentFocusedElement().map({ CFEqual($0, target.element) }) == true else {
            copyOnly(text)
            return .copied("输入焦点已变化，结果已复制")
        }

        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            copyOnly(text)
            return .copied("需要自动粘贴权限，结果已复制")
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let valueBefore = attribute("AXValue", from: target.element) as? String
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        guard postCommandV() else {
            return .copied("无法发送粘贴按键，结果已复制")
        }

        try? await Task.sleep(for: .milliseconds(420))
        let valueAfter = attribute("AXValue", from: target.element) as? String
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
        return .copied("未能确认自动写入，结果已保留在剪贴板")
    }

    private func currentFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        return focusedElement(from: systemWide)
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
