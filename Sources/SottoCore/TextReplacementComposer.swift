import Foundation

public enum TextReplacementSource: Equatable, Sendable {
    case standard
    case codexProseMirror
}

public enum TextReplacementComposer {
    public static func replacing(
        currentValue: String,
        placeholderValue: String?,
        selectedRange: NSRange,
        with replacement: String,
        source: TextReplacementSource = .standard
    ) -> String? {
        let value: String
        if selectedRange.location == 0,
           selectedRange.length == 0,
           let placeholderValue,
           !placeholderValue.isEmpty,
           currentValue == placeholderValue {
            value = ""
        } else if source == .codexProseMirror,
                  isCodexEmptyEditorRepresentation(
                      currentValue,
                      selectedRange: selectedRange
                  ) {
            value = ""
        } else {
            value = currentValue
        }

        let mutable = NSMutableString(string: value)
        guard NSMaxRange(selectedRange) <= mutable.length else { return nil }
        mutable.replaceCharacters(in: selectedRange, with: replacement)
        return mutable as String
    }

    private static func isCodexEmptyEditorRepresentation(
        _ value: String,
        selectedRange: NSRange
    ) -> Bool {
        guard selectedRange.location == 0,
              selectedRange.length == 0,
              value.hasPrefix("\n")
        else {
            return false
        }

        let placeholder = String(value.dropFirst())
        return !placeholder.isEmpty
            && placeholder.count <= 80
            && !placeholder.contains("\n")
    }
}
