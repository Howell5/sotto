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
    public let isRegularApplication: Bool

    public init(
        processID: Int32,
        layer: Int,
        alpha: Double,
        width: Double,
        height: Double,
        isRegularApplication: Bool = true
    ) {
        self.processID = processID
        self.layer = layer
        self.alpha = alpha
        self.width = width
        self.height = height
        self.isRegularApplication = isRegularApplication
    }
}

public enum WindowFocusCandidatePolicy {
    public static func frontmostNormalProcessID(
        _ candidates: [WindowFocusCandidate],
        excluding excludedProcessID: Int32
    ) -> Int32? {
        let eligibleCandidates = candidates.filter {
            $0.layer == 0
                && $0.alpha > 0
                && $0.width > 0
                && $0.height > 0
                && $0.isRegularApplication
        }
        guard let frontmost = eligibleCandidates.first else {
            return nil
        }
        if frontmost.processID != excludedProcessID {
            return frontmost.processID
        }
        return nil
    }
}

public enum FocusedTextResolutionRetryPolicy {
    private static let delays = [20, 40, 80]

    public static func delayMilliseconds(
        afterFailedAttemptCount failedAttemptCount: Int
    ) -> Int? {
        guard failedAttemptCount > 0,
              failedAttemptCount <= delays.count
        else {
            return nil
        }
        return delays[failedAttemptCount - 1]
    }

    public static func shouldIncludeWindowTraversal(
        onAttempt attempt: Int
    ) -> Bool {
        attempt == delays.count + 1
    }
}

public struct FocusedTextCandidateSnapshot: Equatable, Sendable {
    public let role: String?
    public let valueIsWritable: Bool
    public let hasTextSelection: Bool
    public let isDOMBacked: Bool
    public let isExplicitEditableAncestor: Bool

    public init(
        role: String?,
        valueIsWritable: Bool,
        hasTextSelection: Bool,
        isDOMBacked: Bool = false,
        isExplicitEditableAncestor: Bool = false
    ) {
        self.role = role
        self.valueIsWritable = valueIsWritable
        self.hasTextSelection = hasTextSelection
        self.isDOMBacked = isDOMBacked
        self.isExplicitEditableAncestor = isExplicitEditableAncestor
    }
}

public enum FocusedTextNormalizationPolicy {
    public static func normalizedEditableIndex(
        in focusedElementToAncestorPath: [FocusedTextCandidateSnapshot]
    ) -> Int? {
        focusedElementToAncestorPath.firstIndex(where: isEditable)
    }

    public static func isEditable(
        _ candidate: FocusedTextCandidateSnapshot
    ) -> Bool {
        let isStandardTextControl = FocusedTextCandidatePolicy.isEligible(
            role: candidate.role,
            isFocused: true
        )
        if isStandardTextControl {
            return candidate.valueIsWritable || candidate.hasTextSelection
        }
        return candidate.role == "AXGroup"
            && candidate.isDOMBacked
            && (
                candidate.valueIsWritable
                    || candidate.isExplicitEditableAncestor
            )
    }
}

public enum FocusResolutionSource: Equatable, Sendable {
    case systemWide
    case application
    case windowDescendant
}

public enum FocusResolutionSourcePolicy {
    public static func choose(
        systemWideCandidateIsEditable: Bool,
        applicationCandidateIsEditable: Bool,
        windowDescendantIsEditable: Bool
    ) -> FocusResolutionSource? {
        if systemWideCandidateIsEditable {
            return .systemWide
        }
        if applicationCandidateIsEditable {
            return .application
        }
        if windowDescendantIsEditable {
            return .windowDescendant
        }
        return nil
    }
}

public enum FrontmostProcessCandidatePolicy {
    public static func processIDs(
        frontmostProcessID: Int32,
        isOwnProcess: Bool,
        isRegularApplication: Bool,
        regularAncestorProcessID: Int32?,
        globallyFocusedProcessIDs: [Int32]
    ) -> [Int32] {
        guard !isOwnProcess else {
            return []
        }
        var processIDs = [frontmostProcessID]
        if !isRegularApplication,
           let regularAncestorProcessID,
           regularAncestorProcessID != frontmostProcessID,
           globallyFocusedProcessIDs.contains(regularAncestorProcessID) {
            processIDs.append(regularAncestorProcessID)
        }
        return processIDs
    }
}

public enum FocusedDescendantTraversalPolicy {
    public static func shouldNormalize(
        role _: String?,
        isFocused: Bool
    ) -> Bool {
        isFocused
    }
}

public enum CurrentTargetFocusPolicy {
    public static func isStillFocused(
        sameElementAsFocusedElement: Bool,
        containsFocusedElement: Bool,
        targetReportsFocused: Bool
    ) -> Bool {
        sameElementAsFocusedElement
            || containsFocusedElement
            || targetReportsFocused
    }
}

public enum CurrentFocusValidationSource: Equatable, Sendable {
    case systemWide
    case application
    case reject
    case unavailable
}

public enum CurrentFocusValidationSourcePolicy {
    public static func choose(
        systemWideFocusedProcessID: Int32?,
        targetProcessID: Int32,
        applicationFocusIsAvailable: Bool
    ) -> CurrentFocusValidationSource {
        if let systemWideFocusedProcessID {
            return systemWideFocusedProcessID == targetProcessID
                ? .systemWide
                : .reject
        }
        return applicationFocusIsAvailable
            ? .application
            : .unavailable
    }
}

public enum FocusProcessFreshnessPolicy {
    public static func isCurrent(
        resolvedProcessID: Int32,
        eligibleFrontmostProcessIDs: [Int32]
    ) -> Bool {
        eligibleFrontmostProcessIDs.contains(resolvedProcessID)
    }
}

public enum FocusedEditableCandidateSource: Equatable, Sendable {
    case highestEditableAncestor
    case editableAncestor
    case focusedElement
}

public enum FocusedEditableCandidateOrderingPolicy {
    public static func preferredSources(
        hasHighestEditableAncestor: Bool,
        hasEditableAncestor: Bool
    ) -> [FocusedEditableCandidateSource] {
        var sources: [FocusedEditableCandidateSource] = []
        if hasHighestEditableAncestor {
            sources.append(.highestEditableAncestor)
        }
        if hasEditableAncestor {
            sources.append(.editableAncestor)
        }
        sources.append(.focusedElement)
        return sources
    }
}
