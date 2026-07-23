public enum FocusedTextCandidatePolicy {
    private static let eligibleRoles = [
        "AXTextArea",
        "AXTextField",
        "AXComboBox"
    ]

    public static func isEligible(
        role: String?,
        isFocused: Bool
    ) -> Bool {
        isFocused && role.map(eligibleRoles.contains) == true
    }
}

public struct WindowFocusCandidate: Equatable, Sendable {
    public let processID: Int32
    public let layer: Int
    public let alpha: Double
    public let width: Double
    public let height: Double

    public init(
        processID: Int32,
        layer: Int,
        alpha: Double,
        width: Double,
        height: Double
    ) {
        self.processID = processID
        self.layer = layer
        self.alpha = alpha
        self.width = width
        self.height = height
    }
}

public enum WindowFocusCandidatePolicy {
    public static func frontmostNormalProcessID(
        _ candidates: [WindowFocusCandidate],
        excluding excludedProcessID: Int32
    ) -> Int32? {
        guard let frontmost = candidates.first(where: {
            $0.layer == 0
                && $0.alpha > 0
                && $0.width > 0
                && $0.height > 0
        }) else {
            return nil
        }
        guard frontmost.processID != excludedProcessID else {
            return nil
        }
        return frontmost.processID
    }
}

public enum TextTargetIdentityPolicy {
    public static func isSameTarget(
        sameElement: Bool
    ) -> Bool {
        sameElement
    }
}
