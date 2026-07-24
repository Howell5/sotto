public struct InsertionTargetCapabilities: Equatable, Sendable {
    public let isSameFocusedElement: Bool
    public let isSecure: Bool
    public let isNativeTextControl: Bool
    public let valueIsWritable: Bool
    public let hasSelectedTextRange: Bool

    public init(
        isSameFocusedElement: Bool,
        isSecure: Bool,
        isNativeTextControl: Bool,
        valueIsWritable: Bool,
        hasSelectedTextRange: Bool
    ) {
        self.isSameFocusedElement = isSameFocusedElement
        self.isSecure = isSecure
        self.isNativeTextControl = isNativeTextControl
        self.valueIsWritable = valueIsWritable
        self.hasSelectedTextRange = hasSelectedTextRange
    }
}

public enum InsertionCopyReason: Equatable, Sendable {
    case secureField
    case focusChanged
}

public enum InsertionStrategy: Equatable, Sendable {
    case directValueReplacement
    case pasteboard
    case copyOnly(reason: InsertionCopyReason)
}

public enum InsertionStrategyResolver {
    public static func resolve(
        _ target: InsertionTargetCapabilities,
        source: TextReplacementSource = .standard
    ) -> InsertionStrategy {
        guard target.isSameFocusedElement else {
            return .copyOnly(reason: .focusChanged)
        }
        guard !target.isSecure else {
            return .copyOnly(reason: .secureField)
        }
        if source == .codexProseMirror || source == .webContent {
            return .pasteboard
        }
        if target.isNativeTextControl,
           target.valueIsWritable,
           target.hasSelectedTextRange {
            return .directValueReplacement
        }
        return .pasteboard
    }
}
