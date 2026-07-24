import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import OSLog
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

    private static let logger = Logger(
        subsystem: "com.willhong.sotto",
        category: "TextInsertion"
    )
    private let maximumFallbackNodeCount = 5_000
    private let maximumEditableAncestorDepth = 24

    func insert(_ text: String) async -> TextInsertionOutcome {
        guard AXIsProcessTrusted() else {
            copyOnly(text)
            return .copied(
                ClipboardRecoveryCopy.message(reason: "需要辅助功能权限")
            )
        }
        guard let target = await resolveFocusedTargetWithRetry() else {
            copyOnly(text)
            return .copied(
                ClipboardRecoveryCopy.message(reason: "未识别到输入框")
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

        guard validatedCurrentTarget(target) != nil else {
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
        guard !capabilities(for: target).isSecure else {
            copyOnly(text)
            return .copied(
                ClipboardRecoveryCopy.message(
                    reason: "安全输入框不会自动写入"
                )
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
        let valueBefore = attribute("AXValue", from: target.element) as? String
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        guard let commitTarget = validatedCurrentTarget(target) else {
            return .copied(
                ClipboardRecoveryCopy.message(reason: "输入焦点已变化")
            )
        }
        guard !capabilities(for: commitTarget).isSecure else {
            return .copied(
                ClipboardRecoveryCopy.message(
                    reason: "安全输入框不会自动写入"
                )
            )
        }
        guard postCommandV() else {
            return .copied(
                ClipboardRecoveryCopy.message(reason: "无法发送粘贴按键")
            )
        }

        try? await Task.sleep(for: .milliseconds(420))
        let valueAfter = attribute(
            "AXValue",
            from: commitTarget.element
        ) as? String
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

    private func resolveFocusedTargetWithRetry() async -> FocusedTextTarget? {
        var failedAttemptCount = 0

        while true {
            let attempt = failedAttemptCount + 1
            if let focus = resolveFocusedElement(
                includeWindowTraversal:
                    FocusedTextResolutionRetryPolicy
                        .shouldIncludeWindowTraversal(
                            onAttempt: attempt
                        )
            ) {
                return makeTarget(from: focus)
            }

            failedAttemptCount += 1
            guard let delay = FocusedTextResolutionRetryPolicy
                .delayMilliseconds(
                    afterFailedAttemptCount: failedAttemptCount
            )
            else {
                let processIDs = frontmostExternalProcessIDs()
                    .map(String.init)
                    .joined(separator: ",")
                Self.logger.error(
                    "No editable AX target after \(failedAttemptCount, privacy: .public) attempts; pids=\(processIDs, privacy: .public)"
                )
                return nil
            }
            try? await Task.sleep(for: .milliseconds(delay))
        }
    }

    private func validatedCurrentTarget(
        _ target: FocusedTextTarget
    ) -> FocusedTextTarget? {
        guard frontmostExternalProcessIDs().contains(target.processID) else {
            return nil
        }

        let application = AXUIElementCreateApplication(target.processID)
        let systemFocusedElement = focusedElement(
            from: AXUIElementCreateSystemWide()
        )
        var systemFocusedProcessID: pid_t?
        if let systemFocusedElement {
            var processID: pid_t = 0
            if AXUIElementGetPid(
                systemFocusedElement,
                &processID
            ) == .success {
                systemFocusedProcessID = processID
            }
        }
        let applicationFocusedElement = focusedElement(from: application)
        let targetReportsFocused =
            attribute("AXFocused", from: target.element) as? Bool == true
        let focusedElement: AXUIElement?
        switch CurrentFocusValidationSourcePolicy.choose(
            systemWideFocusedProcessID: systemFocusedProcessID,
            targetProcessID: target.processID,
            applicationFocusIsAvailable:
                applicationFocusedElement != nil || targetReportsFocused
        ) {
        case .systemWide:
            focusedElement = systemFocusedElement
        case .application:
            focusedElement = applicationFocusedElement
        case .reject, .unavailable:
            return nil
        }
        guard CurrentTargetFocusPolicy.isStillFocused(
            sameElementAsFocusedElement:
                focusedElement.map { CFEqual($0, target.element) } ?? false,
            containsFocusedElement:
                focusedElement.map {
                    isAncestor(target.element, of: $0)
                } ?? false,
            targetReportsFocused:
                focusedElement == nil && targetReportsFocused
        ),
              let element = normalizedEditableElement(from: target.element)
        else {
            return nil
        }
        return makeTarget(
            from: ResolvedFocus(
                element: element,
                processID: target.processID
            )
        )
    }

    private func resolveFocusedElement(
        includeWindowTraversal: Bool
    ) -> ResolvedFocus? {
        let eligibleProcessIDs = frontmostExternalProcessIDs()
        guard !eligibleProcessIDs.isEmpty else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        let systemWideCandidate = focusedElement(from: systemWide)
            .flatMap {
                normalizedResolvedFocus(
                    for: $0,
                    expectedProcessID: nil
                )
            }
        if FocusResolutionSourcePolicy.choose(
            systemWideCandidateIsEditable: systemWideCandidate != nil,
            applicationCandidateIsEditable: false,
            windowDescendantIsEditable: false
        ) == .systemWide,
        let systemWideCandidate,
        isCurrentFocus(
            systemWideCandidate,
            eligibleProcessIDs: eligibleProcessIDs
        ) {
            return systemWideCandidate
        }

        for processID in eligibleProcessIDs {
            let application = AXUIElementCreateApplication(processID)
            let applicationCandidate = focusedElement(from: application)
                .flatMap {
                    normalizedResolvedFocus(
                        for: $0,
                        expectedProcessID: processID
                    )
                }
            if FocusResolutionSourcePolicy.choose(
                systemWideCandidateIsEditable: false,
                applicationCandidateIsEditable: applicationCandidate != nil,
                windowDescendantIsEditable: false
            ) == .application,
            let applicationCandidate,
            isCurrentFocus(
                applicationCandidate,
                eligibleProcessIDs: eligibleProcessIDs
            ) {
                return applicationCandidate
            }
        }

        guard includeWindowTraversal else {
            return nil
        }
        for processID in eligibleProcessIDs {
            let application = AXUIElementCreateApplication(processID)
            let windowCandidate = elementAttribute(
                "AXFocusedWindow",
                from: application
            )
            .flatMap(focusedTextDescendant)
            .flatMap {
                normalizedResolvedFocus(
                    for: $0,
                    expectedProcessID: processID
                )
            }

            switch FocusResolutionSourcePolicy.choose(
                systemWideCandidateIsEditable: false,
                applicationCandidateIsEditable: false,
                windowDescendantIsEditable: windowCandidate != nil
            ) {
            case .windowDescendant:
                guard let windowCandidate,
                      isCurrentFocus(
                          windowCandidate,
                          eligibleProcessIDs: eligibleProcessIDs
                      )
                else {
                    continue
                }
                return windowCandidate
            case .systemWide, .application, nil:
                continue
            }
        }
        return nil
    }

    private func normalizedResolvedFocus(
        for element: AXUIElement,
        expectedProcessID: pid_t?
    ) -> ResolvedFocus? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success,
              processID != ProcessInfo.processInfo.processIdentifier,
              expectedProcessID.map({ $0 == processID }) ?? true,
              let normalizedElement = normalizedEditableElement(from: element)
        else {
            return nil
        }

        var normalizedProcessID: pid_t = 0
        guard AXUIElementGetPid(
            normalizedElement,
            &normalizedProcessID
        ) == .success,
        normalizedProcessID == processID else {
            return nil
        }
        return ResolvedFocus(
            element: normalizedElement,
            processID: normalizedProcessID
        )
    }

    private func isCurrentFocus(
        _ focus: ResolvedFocus,
        eligibleProcessIDs: [pid_t]? = nil
    ) -> Bool {
        FocusProcessFreshnessPolicy.isCurrent(
            resolvedProcessID: focus.processID,
            eligibleFrontmostProcessIDs:
                eligibleProcessIDs ?? frontmostExternalProcessIDs()
        )
    }

    private func makeTarget(from focus: ResolvedFocus) -> FocusedTextTarget {
        let replacementSource = replacementSource(for: focus.element)
        return FocusedTextTarget(
            element: focus.element,
            processID: focus.processID,
            role: attribute("AXRole", from: focus.element) as? String,
            subrole: attribute("AXSubrole", from: focus.element) as? String,
            replacementSource: replacementSource
        )
    }

    private func replacementSource(
        for element: AXUIElement
    ) -> TextReplacementSource {
        let domClasses = attribute(
            "AXDOMClassList",
            from: element
        ) as? [String] ?? []
        return TextControlOriginPolicy.replacementSource(
            hasWebAreaAncestor: hasAncestor(
                role: "AXWebArea",
                from: element
            ),
            hasDOMIdentifier: attribute(
                "AXDOMIdentifier",
                from: element
            ) is String,
            domClasses: domClasses
        )
    }

    private func focusedTextDescendant(
        from root: AXUIElement
    ) -> AXUIElement? {
        var queue = [root]
        var queuedElements: Set<AXUIElement> = [root]
        var index = 0

        while index < queue.count,
              index < maximumFallbackNodeCount {
            let element = queue[index]
            index += 1
            let role = attribute("AXRole", from: element) as? String
            let isFocused = attribute("AXFocused", from: element) as? Bool
                ?? false
            if FocusedDescendantTraversalPolicy.shouldNormalize(
                role: role,
                isFocused: isFocused
            ), let normalized = normalizedEditableElement(from: element) {
                return normalized
            }
            guard queue.count < maximumFallbackNodeCount else {
                continue
            }
            appendUniqueChildren(
                of: element,
                to: &queue,
                queuedElements: &queuedElements
            )
        }
        return nil
    }

    private func normalizedEditableElement(
        from focusedElement: AXUIElement
    ) -> AXUIElement? {
        let highestEditableAncestor = elementAttribute(
            "AXHighestEditableAncestor",
            from: focusedElement
        )
        let editableAncestor = elementAttribute(
            "AXEditableAncestor",
            from: focusedElement
        )
        var checkedElements = Set<AXUIElement>()
        for source in FocusedEditableCandidateOrderingPolicy.preferredSources(
            hasHighestEditableAncestor: highestEditableAncestor != nil,
            hasEditableAncestor: editableAncestor != nil
        ) {
            let candidate: AXUIElement?
            switch source {
            case .highestEditableAncestor:
                candidate = highestEditableAncestor
            case .editableAncestor:
                candidate = editableAncestor
            case .focusedElement:
                candidate = focusedElement
            }
            if let candidate = editableCandidate(
                candidate,
                isExplicitEditableAncestor:
                    source != .focusedElement,
                checkedElements: &checkedElements
            ) {
                return candidate
            }
        }

        var ancestor = focusedElement
        for _ in 0..<maximumEditableAncestorDepth {
            guard let parent = elementAttribute("AXParent", from: ancestor)
            else {
                break
            }
            if let candidate = editableCandidate(
                parent,
                isExplicitEditableAncestor: false,
                checkedElements: &checkedElements
            ) {
                return candidate
            }
            ancestor = parent
        }
        return nil
    }

    private func editableCandidate(
        _ element: AXUIElement?,
        isExplicitEditableAncestor: Bool,
        checkedElements: inout Set<AXUIElement>
    ) -> AXUIElement? {
        guard let element,
              checkedElements.insert(element).inserted
        else {
            return nil
        }
        let snapshot = candidateSnapshot(
            for: element,
            isExplicitEditableAncestor:
                isExplicitEditableAncestor
        )
        return FocusedTextNormalizationPolicy.isEditable(snapshot)
            ? element
            : nil
    }

    private func candidateSnapshot(
        for element: AXUIElement,
        isExplicitEditableAncestor: Bool
    ) -> FocusedTextCandidateSnapshot {
        var valueSettable = DarwinBoolean(false)
        let valueStatus = AXUIElementIsAttributeSettable(
            element,
            "AXValue" as CFString,
            &valueSettable
        )
        let hasTextSelection =
            attribute("AXSelectedTextRange", from: element) != nil
            || attribute("AXSelectedTextMarkerRange", from: element) != nil
        let role = attribute("AXRole", from: element) as? String
        let isDOMBacked = role == "AXGroup"
            && replacementSource(for: element) == .webContent

        return FocusedTextCandidateSnapshot(
            role: role,
            valueIsWritable:
                valueStatus == .success && valueSettable.boolValue,
            hasTextSelection: hasTextSelection,
            isDOMBacked: isDOMBacked,
            isExplicitEditableAncestor:
                isExplicitEditableAncestor
        )
    }

    private func appendUniqueChildren(
        of element: AXUIElement,
        to queue: inout [AXUIElement],
        queuedElements: inout Set<AXUIElement>
    ) {
        for attributeName in ["AXChildren", "AXVisibleChildren", "AXContents"] {
            guard queue.count < maximumFallbackNodeCount,
                  let children = attribute(
                      attributeName,
                      from: element
                  ) as? [AXUIElement]
            else {
                continue
            }
            for child in children {
                guard queue.count < maximumFallbackNodeCount else {
                    return
                }
                if queuedElements.insert(child).inserted {
                    queue.append(child)
                }
            }
            if !children.isEmpty {
                return
            }
        }
    }

    private func isAncestor(
        _ ancestor: AXUIElement,
        of descendant: AXUIElement
    ) -> Bool {
        if CFEqual(ancestor, descendant) {
            return true
        }
        for attributeName in [
            "AXHighestEditableAncestor",
            "AXEditableAncestor"
        ] {
            if let editableAncestor = elementAttribute(
                attributeName,
                from: descendant
            ), CFEqual(ancestor, editableAncestor) {
                return true
            }
        }

        var current = descendant
        for _ in 0..<maximumEditableAncestorDepth {
            guard let parent = elementAttribute("AXParent", from: current)
            else {
                return false
            }
            if CFEqual(ancestor, parent) {
                return true
            }
            current = parent
        }
        return false
    }

    private func hasAncestor(
        role expectedRole: String,
        from element: AXUIElement
    ) -> Bool {
        var current: AXUIElement? = element

        for _ in 0..<maximumEditableAncestorDepth {
            guard let candidate = current else { return false }
            if attribute("AXRole", from: candidate) as? String == expectedRole {
                return true
            }
            current = elementAttribute("AXParent", from: candidate)
        }
        return false
    }

    private func frontmostExternalProcessIDs() -> [pid_t] {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        guard let frontmostApplication =
            NSWorkspace.shared.frontmostApplication
        else {
            return frontmostNormalWindowProcessID().map { [$0] } ?? []
        }

        let frontmostProcessID = frontmostApplication.processIdentifier
        let regularAncestorProcessID =
            frontmostApplication.activationPolicy == .regular
                ? nil
                : regularApplicationAncestorProcessID(
                    of: frontmostProcessID
                )
        return FrontmostProcessCandidatePolicy.processIDs(
            frontmostProcessID: frontmostProcessID,
            isOwnProcess: belongsToProcessFamily(
                processID: frontmostProcessID,
                ancestorProcessID: ownProcessID
            ),
            isRegularApplication:
                frontmostApplication.activationPolicy == .regular,
            regularAncestorProcessID: regularAncestorProcessID,
            globallyFocusedProcessIDs: globallyFocusedProcessIDs()
        )
    }

    private func globallyFocusedProcessIDs() -> [pid_t] {
        let systemWide = AXUIElementCreateSystemWide()
        var processIDs: [pid_t] = []
        var seenProcessIDs = Set<pid_t>()
        let focusedElements = [
            elementAttribute("AXFocusedApplication", from: systemWide),
            focusedElement(from: systemWide)
        ]

        for element in focusedElements.compactMap({ $0 }) {
            var processID: pid_t = 0
            guard AXUIElementGetPid(element, &processID) == .success,
                  processID > 0,
                  seenProcessIDs.insert(processID).inserted
            else {
                continue
            }
            processIDs.append(processID)
        }
        return processIDs
    }

    private func regularApplicationAncestorProcessID(
        of processID: pid_t
    ) -> pid_t? {
        var currentProcessID = processID
        var visitedProcessIDs: Set<pid_t> = [processID]

        for _ in 0..<8 {
            guard let parentProcessID = parentProcessID(
                of: currentProcessID
            ),
            parentProcessID > 1,
            visitedProcessIDs.insert(parentProcessID).inserted
            else {
                return nil
            }
            if NSRunningApplication(
                processIdentifier: parentProcessID
            )?.activationPolicy == .regular {
                return parentProcessID
            }
            currentProcessID = parentProcessID
        }
        return nil
    }

    private func belongsToProcessFamily(
        processID: pid_t,
        ancestorProcessID: pid_t
    ) -> Bool {
        if processID == ancestorProcessID {
            return true
        }
        var currentProcessID = processID
        var visitedProcessIDs: Set<pid_t> = [processID]

        for _ in 0..<8 {
            guard let parentProcessID = parentProcessID(
                of: currentProcessID
            ),
            parentProcessID > 1,
            visitedProcessIDs.insert(parentProcessID).inserted
            else {
                return false
            }
            if parentProcessID == ancestorProcessID {
                return true
            }
            currentProcessID = parentProcessID
        }
        return false
    }

    private func parentProcessID(of processID: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard actualSize == expectedSize else {
            return nil
        }
        return pid_t(info.pbi_ppid)
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
                height: bounds.height,
                isRegularApplication: NSRunningApplication(
                    processIdentifier: processID
                )?.activationPolicy == .regular
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
