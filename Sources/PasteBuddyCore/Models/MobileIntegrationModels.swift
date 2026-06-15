import Foundation

public enum MobileIntegrationSurface: String, CaseIterable, Codable, Identifiable, Sendable {
    case iPhoneApp
    case iPadApp
    case keyboardExtension
    case shareExtension
    case actionExtension

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iPhoneApp: "iPhone App"
        case .iPadApp: "iPad App"
        case .keyboardExtension: "Keyboard Extension"
        case .shareExtension: "Share Extension"
        case .actionExtension: "Action Extension"
        }
    }
}

public enum MobileIPadMultitaskingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case stageManager
    case splitView
    case slideOver
    case dragAndDrop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stageManager: "Stage Manager"
        case .splitView: "Split View"
        case .slideOver: "Slide Over"
        case .dragAndDrop: "Drag and Drop"
        }
    }
}

public struct MobileBrowsingCapabilities: Equatable, Sendable {
    public var canBrowseHistory: Bool
    public var canBrowsePinboards: Bool
    public var canSearchKeywords: Bool
    public var structuredFilterKinds: [ClipboardFilterKind]
    public var supportsFullScreenPreview: Bool
    public var supportsOriginalCopy: Bool
    public var supportsPlainTextCopy: Bool
    public var supportsContextMenus: Bool
    public var supportsPinboardDragAndDrop: Bool
    public var iPadMultitaskingModes: [MobileIPadMultitaskingMode]
    public var backgroundClipboardLimitation: String

    public init(
        canBrowseHistory: Bool = true,
        canBrowsePinboards: Bool = true,
        canSearchKeywords: Bool = true,
        structuredFilterKinds: [ClipboardFilterKind] = [.contentType, .sourceApp, .device, .date],
        supportsFullScreenPreview: Bool = true,
        supportsOriginalCopy: Bool = true,
        supportsPlainTextCopy: Bool = true,
        supportsContextMenus: Bool = true,
        supportsPinboardDragAndDrop: Bool = true,
        iPadMultitaskingModes: [MobileIPadMultitaskingMode] = MobileIPadMultitaskingMode.allCases,
        backgroundClipboardLimitation: String = "iOS and iPadOS do not permit dependable continuous background clipboard monitoring. PasteBuddy should browse synced or manually imported encrypted history, read the pasteboard only after foreground permission, and rely on Share or Action extensions for manual imports."
    ) {
        self.canBrowseHistory = canBrowseHistory
        self.canBrowsePinboards = canBrowsePinboards
        self.canSearchKeywords = canSearchKeywords
        self.structuredFilterKinds = structuredFilterKinds
        self.supportsFullScreenPreview = supportsFullScreenPreview
        self.supportsOriginalCopy = supportsOriginalCopy
        self.supportsPlainTextCopy = supportsPlainTextCopy
        self.supportsContextMenus = supportsContextMenus
        self.supportsPinboardDragAndDrop = supportsPinboardDragAndDrop
        self.iPadMultitaskingModes = iPadMultitaskingModes
        self.backgroundClipboardLimitation = backgroundClipboardLimitation
    }
}

public struct MobileKeyboardExtensionCapabilities: Equatable, Sendable {
    public var supportsGlobeSwitcherActivation: Bool
    public var canBrowseHistory: Bool
    public var canBrowsePinboards: Bool
    public var supportsTextInsertion: Bool
    public var supportsPlainTextCopy: Bool
    public var supportsDragAndDrop: Bool
    public var supportsLongPressActions: Bool
    public var iPadLayoutModes: [MobileIPadMultitaskingMode]
    public var fullAccessPrivacyExplanation: String

    public init(
        supportsGlobeSwitcherActivation: Bool = true,
        canBrowseHistory: Bool = true,
        canBrowsePinboards: Bool = true,
        supportsTextInsertion: Bool = true,
        supportsPlainTextCopy: Bool = true,
        supportsDragAndDrop: Bool = true,
        supportsLongPressActions: Bool = true,
        iPadLayoutModes: [MobileIPadMultitaskingMode] = [.stageManager, .splitView, .slideOver, .dragAndDrop],
        fullAccessPrivacyExplanation: String = "Full Access lets the keyboard read PasteBuddy's encrypted shared App Group history and insert selected text. Clipboard data stays on the user's device or private iCloud account unless the user explicitly enables sync or sharing."
    ) {
        self.supportsGlobeSwitcherActivation = supportsGlobeSwitcherActivation
        self.canBrowseHistory = canBrowseHistory
        self.canBrowsePinboards = canBrowsePinboards
        self.supportsTextInsertion = supportsTextInsertion
        self.supportsPlainTextCopy = supportsPlainTextCopy
        self.supportsDragAndDrop = supportsDragAndDrop
        self.supportsLongPressActions = supportsLongPressActions
        self.iPadLayoutModes = iPadLayoutModes
        self.fullAccessPrivacyExplanation = fullAccessPrivacyExplanation
    }
}

public struct MobileShareActionExtensionCapabilities: Equatable, Sendable {
    public var supportedContentTypes: [ClipboardContentType]
    public var canChooseTargetPinboard: Bool
    public var supportsShareExtension: Bool
    public var supportsActionExtension: Bool
    public var supportsShareSheetFavoritesAndReorder: Bool
    public var unsupportedInputExplanation: String
    public var favoriteReorderGuidance: String

    public init(
        supportedContentTypes: [ClipboardContentType] = [.text, .url, .image, .file],
        canChooseTargetPinboard: Bool = true,
        supportsShareExtension: Bool = true,
        supportsActionExtension: Bool = true,
        supportsShareSheetFavoritesAndReorder: Bool = true,
        unsupportedInputExplanation: String = "PasteBuddy can save shared text, links, images, and supported file URLs. Unsupported provider payloads should fail with a clear message and no plaintext temporary files.",
        favoriteReorderGuidance: String = "Users can add Save to PasteBuddy and Copy to PasteBuddy to iOS Share sheet favorites and reorder them from the system Share sheet edit screen."
    ) {
        self.supportedContentTypes = supportedContentTypes
        self.canChooseTargetPinboard = canChooseTargetPinboard
        self.supportsShareExtension = supportsShareExtension
        self.supportsActionExtension = supportsActionExtension
        self.supportsShareSheetFavoritesAndReorder = supportsShareSheetFavoritesAndReorder
        self.unsupportedInputExplanation = unsupportedInputExplanation
        self.favoriteReorderGuidance = favoriteReorderGuidance
    }
}

public enum IOSPastePermissionState: String, CaseIterable, Codable, Identifiable, Sendable {
    case unknown
    case ask
    case allowed
    case denied

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .ask: "Ask"
        case .allowed: "Allowed"
        case .denied: "Denied"
        }
    }
}

public struct MobileOnboardingStep: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var isComplete: Bool

    public init(id: String, title: String, detail: String, isComplete: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
    }
}

public enum MobileGuidanceSeverity: String, CaseIterable, Codable, Equatable, Sendable {
    case ready
    case optional
    case actionRequired

    public var displayName: String {
        switch self {
        case .ready: "Ready"
        case .optional: "Optional"
        case .actionRequired: "Action Required"
        }
    }
}

public enum MobileGuidanceActionKind: String, CaseIterable, Codable, Equatable, Sendable {
    case openAppSettings
    case openKeyboardSettings
    case enableShareExtension
    case enableActionExtension
    case configureAppGroup
    case continueManualImport

    public var displayName: String {
        switch self {
        case .openAppSettings: "Open App Settings"
        case .openKeyboardSettings: "Open Keyboard Settings"
        case .enableShareExtension: "Enable Share Extension"
        case .enableActionExtension: "Enable Action Extension"
        case .configureAppGroup: "Configure App Group"
        case .continueManualImport: "Continue Manual Import"
        }
    }
}

public struct MobileGuidanceAction: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var kind: MobileGuidanceActionKind
    public var title: String
    public var detail: String
    public var isPrimary: Bool

    public init(
        id: String,
        kind: MobileGuidanceActionKind,
        title: String,
        detail: String,
        isPrimary: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isPrimary = isPrimary
    }
}

public struct MobileGuidanceCard: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var surface: MobileIntegrationSurface
    public var severity: MobileGuidanceSeverity
    public var title: String
    public var detail: String
    public var isComplete: Bool
    public var actions: [MobileGuidanceAction]

    public init(
        id: String,
        surface: MobileIntegrationSurface,
        severity: MobileGuidanceSeverity,
        title: String,
        detail: String,
        isComplete: Bool,
        actions: [MobileGuidanceAction] = []
    ) {
        self.id = id
        self.surface = surface
        self.severity = severity
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
        self.actions = actions
    }
}

public enum MobileAutomaticCaptureStatus: String, CaseIterable, Codable, Equatable, Sendable {
    case available
    case needsUserConsent
    case denied
    case explainFirst

    public var displayName: String {
        switch self {
        case .available: "Available"
        case .needsUserConsent: "Needs User Consent"
        case .denied: "Denied"
        case .explainFirst: "Explain First"
        }
    }
}

public struct MobilePastePermissionGuidance: Equatable, Sendable {
    public var state: IOSPastePermissionState
    public var automaticCaptureStatus: MobileAutomaticCaptureStatus
    public var title: String
    public var detail: String
    public var settingsPath: String
    public var shouldOfferSettingsAction: Bool
    public var canUseManualWorkflows: Bool
    public var manualWorkflowMessage: String
    public var darkPatternGuardrail: String

    public init(configuration: MobileIntegrationConfiguration) {
        self.state = configuration.pastePermissionState
        self.settingsPath = "Settings > Apps > PasteBuddy > Allow Paste From Other Apps > Allow"
        self.canUseManualWorkflows = true
        self.manualWorkflowMessage = "Manual workflows remain available: browsing synced encrypted history, keyboard access, Share extension imports, and Action extension imports continue when automatic pasteboard capture is not allowed."
        self.darkPatternGuardrail = "Do not block app launch, hide manual workflows, or imply clipboard data leaves the device/iCloud to pressure the user into enabling Allow."

        switch configuration.pastePermissionState {
        case .allowed:
            self.automaticCaptureStatus = .available
            self.title = "Automatic capture is allowed"
            self.detail = "PasteBuddy may read pasteboard content after foreground user activity and local privacy rules still apply before anything is saved."
            self.shouldOfferSettingsAction = false
        case .ask:
            self.automaticCaptureStatus = .needsUserConsent
            self.title = "Allow Paste From Other Apps is set to Ask"
            self.detail = "iOS will ask before PasteBuddy reads pasteboard content. Offer the Settings path only when the user wants automatic capture."
            self.shouldOfferSettingsAction = true
        case .denied:
            self.automaticCaptureStatus = .denied
            self.title = "Paste access is denied"
            self.detail = "Automatic pasteboard capture is disabled. PasteBuddy should keep manual workflows available and offer Settings without blocking the app."
            self.shouldOfferSettingsAction = true
        case .unknown:
            self.automaticCaptureStatus = .explainFirst
            self.title = "Paste permission has not been checked"
            self.detail = "Explain why iOS asks before reading pasteboard content before attempting automatic capture."
            self.shouldOfferSettingsAction = false
        }
    }
}

public struct MobileIntegrationGuidanceReport: Equatable, Sendable {
    public var configuration: MobileIntegrationConfiguration
    public var cards: [MobileGuidanceCard]

    public init(configuration: MobileIntegrationConfiguration) {
        self.configuration = configuration
        self.cards = Self.makeCards(for: configuration)
    }

    public var needsUserAction: Bool {
        cards.contains { $0.severity == .actionRequired }
    }

    public var canAttemptAutomaticPasteCapture: Bool {
        configuration.pastePermissionState == .allowed
    }

    public var canUseManualExtensionImports: Bool {
        configuration.isShareExtensionEnabled || configuration.isActionExtensionEnabled
    }

    public var pastePermissionGuidance: MobilePastePermissionGuidance {
        MobilePastePermissionGuidance(configuration: configuration)
    }

    public var browsingCapabilities: MobileBrowsingCapabilities {
        configuration.browsingCapabilities
    }

    public var keyboardCapabilities: MobileKeyboardExtensionCapabilities {
        configuration.keyboardCapabilities
    }

    public var shareActionCapabilities: MobileShareActionExtensionCapabilities {
        configuration.shareActionCapabilities
    }

    public var summary: String {
        if needsUserAction {
            return "Mobile setup needs \(cards.filter { $0.severity == .actionRequired }.count) action\(cards.filter { $0.severity == .actionRequired }.count == 1 ? "" : "s")."
        }
        if cards.contains(where: { $0.severity == .optional }) {
            return "Mobile browsing is ready; optional extensions can be enabled later."
        }
        return "Mobile browsing and extensions are ready."
    }

    public func card(id: String) -> MobileGuidanceCard? {
        cards.first { $0.id == id }
    }

    private static func makeCards(for configuration: MobileIntegrationConfiguration) -> [MobileGuidanceCard] {
        [
            iPadMultitaskingCard(),
            backgroundCaptureLimitCard(),
            pastePermissionCard(for: configuration),
            keyboardCard(for: configuration),
            shareExtensionCard(for: configuration),
            actionExtensionCard(for: configuration),
            appGroupCard(for: configuration)
        ]
    }

    private static func iPadMultitaskingCard() -> MobileGuidanceCard {
        MobileGuidanceCard(
            id: "ipad-multitasking",
            surface: .iPadApp,
            severity: .ready,
            title: "iPad browsing adapts to multitasking",
            detail: "The native mobile browser uses an adaptive split layout for portrait, landscape, Stage Manager, Split View, Slide Over, and drag-and-drop into pinboards.",
            isComplete: true
        )
    }

    private static func backgroundCaptureLimitCard() -> MobileGuidanceCard {
        MobileGuidanceCard(
            id: "ios-background-capture-limit",
            surface: .iPhoneApp,
            severity: .ready,
            title: "Background clipboard capture is limited",
            detail: MobileBrowsingCapabilities().backgroundClipboardLimitation,
            isComplete: true
        )
    }

    private static func pastePermissionCard(for configuration: MobileIntegrationConfiguration) -> MobileGuidanceCard {
        let guidance = MobilePastePermissionGuidance(configuration: configuration)
        switch configuration.pastePermissionState {
        case .allowed:
            return MobileGuidanceCard(
                id: "ios-paste-permission",
                surface: .iPhoneApp,
                severity: .ready,
                title: "Paste access is allowed",
                detail: guidance.detail,
                isComplete: true,
                actions: [
                    MobileGuidanceAction(
                        id: "review-app-settings",
                        kind: .openAppSettings,
                        title: "Review App Settings",
                        detail: "Use the iOS app target to open PasteBuddy settings when the user wants to change paste access."
                    )
                ]
            )
        case .ask:
            return MobileGuidanceCard(
                id: "ios-paste-permission",
                surface: .iPhoneApp,
                severity: .actionRequired,
                title: guidance.title,
                detail: "\(guidance.detail) \(guidance.manualWorkflowMessage)",
                isComplete: false,
                actions: [
                    MobileGuidanceAction(
                        id: "open-app-settings",
                        kind: .openAppSettings,
                        title: "Open PasteBuddy Settings",
                        detail: guidance.settingsPath,
                        isPrimary: true
                    ),
                    MobileGuidanceAction(
                        id: "continue-manual-import",
                        kind: .continueManualImport,
                        title: "Use Manual Import",
                        detail: "Share and Action extensions can still save selected content without automatic pasteboard reads."
                    )
                ]
            )
        case .denied:
            return MobileGuidanceCard(
                id: "ios-paste-permission",
                surface: .iPhoneApp,
                severity: .actionRequired,
                title: guidance.title,
                detail: "\(guidance.detail) PasteBuddy must not treat denial as fatal. \(guidance.manualWorkflowMessage)",
                isComplete: false,
                actions: [
                    MobileGuidanceAction(
                        id: "open-app-settings",
                        kind: .openAppSettings,
                        title: "Open PasteBuddy Settings",
                        detail: guidance.settingsPath,
                        isPrimary: true
                    ),
                    MobileGuidanceAction(
                        id: "continue-manual-import",
                        kind: .continueManualImport,
                        title: "Continue Without Automatic Capture",
                        detail: "Use Share or Action extension imports while paste access remains denied."
                    )
                ]
            )
        case .unknown:
            return MobileGuidanceCard(
                id: "ios-paste-permission",
                surface: .iPhoneApp,
                severity: .optional,
                title: guidance.title,
                detail: guidance.detail,
                isComplete: false,
                actions: [
                    MobileGuidanceAction(
                        id: "open-app-settings",
                        kind: .openAppSettings,
                        title: "Prepare Settings Guidance",
                        detail: "Show the settings path when the user opts into automatic capture."
                    )
                ]
            )
        }
    }

    private static func keyboardCard(for configuration: MobileIntegrationConfiguration) -> MobileGuidanceCard {
        guard configuration.isKeyboardExtensionEnabled else {
            return MobileGuidanceCard(
                id: "keyboard-extension",
                surface: .keyboardExtension,
                severity: .optional,
                title: "Keyboard extension is optional",
                detail: "Users can browse the main iOS app without enabling the custom keyboard. When enabled, PasteBuddy appears from the globe keyboard switcher.",
                isComplete: false,
                actions: [
                    MobileGuidanceAction(
                        id: "open-keyboard-settings",
                        kind: .openKeyboardSettings,
                        title: "Enable Keyboard Later",
                        detail: "Add PasteBuddy from iOS Keyboard settings when in-app paste access is needed."
                    )
                ]
            )
        }

        if configuration.hasKeyboardFullAccess {
            return MobileGuidanceCard(
                id: "keyboard-extension",
                surface: .keyboardExtension,
                severity: .ready,
                title: "Keyboard Full Access is enabled",
                detail: configuration.keyboardCapabilities.fullAccessPrivacyExplanation,
                isComplete: true
            )
        }

        return MobileGuidanceCard(
            id: "keyboard-extension",
            surface: .keyboardExtension,
            severity: .actionRequired,
            title: "Keyboard Full Access is needed",
            detail: "Without Full Access, the keyboard should stay in limited mode and avoid claiming it can read synced encrypted history. \(configuration.keyboardCapabilities.fullAccessPrivacyExplanation)",
            isComplete: false,
            actions: [
                MobileGuidanceAction(
                    id: "open-keyboard-settings",
                    kind: .openKeyboardSettings,
                    title: "Open Keyboard Settings",
                    detail: "Enable Full Access only after explaining that the keyboard reads PasteBuddy's encrypted shared history.",
                    isPrimary: true
                )
            ]
        )
    }

    private static func shareExtensionCard(for configuration: MobileIntegrationConfiguration) -> MobileGuidanceCard {
        MobileGuidanceCard(
            id: "share-extension",
            surface: .shareExtension,
            severity: configuration.isShareExtensionEnabled ? .ready : .optional,
            title: configuration.isShareExtensionEnabled ? "Share extension is enabled" : "Share extension is available",
            detail: configuration.isShareExtensionEnabled
                ? "Selected text, URLs, images, and files can be saved into encrypted history or a selected pinboard. \(configuration.shareActionCapabilities.favoriteReorderGuidance)"
                : "Enable the Share extension when users want to save content from other apps without automatic pasteboard capture. \(configuration.shareActionCapabilities.favoriteReorderGuidance)",
            isComplete: configuration.isShareExtensionEnabled,
            actions: configuration.isShareExtensionEnabled ? [] : [
                MobileGuidanceAction(
                    id: "enable-share-extension",
                    kind: .enableShareExtension,
                    title: "Enable Share Extension",
                    detail: "Add PasteBuddy to the iOS Share sheet favorites.",
                    isPrimary: true
                )
            ]
        )
    }

    private static func actionExtensionCard(for configuration: MobileIntegrationConfiguration) -> MobileGuidanceCard {
        MobileGuidanceCard(
            id: "action-extension",
            surface: .actionExtension,
            severity: configuration.isActionExtensionEnabled ? .ready : .optional,
            title: configuration.isActionExtensionEnabled ? "Action extension is enabled" : "Action extension is available",
            detail: configuration.isActionExtensionEnabled
                ? "The action extension can save supported selections directly into encrypted history or the preferred pinboard."
                : "Enable the action extension for one-tap Copy to PasteBuddy actions in compatible apps.",
            isComplete: configuration.isActionExtensionEnabled,
            actions: configuration.isActionExtensionEnabled ? [] : [
                MobileGuidanceAction(
                    id: "enable-action-extension",
                    kind: .enableActionExtension,
                    title: "Enable Action Extension",
                    detail: "Expose PasteBuddy as a reusable iOS action.",
                    isPrimary: true
                )
            ]
        )
    }

    private static func appGroupCard(for configuration: MobileIntegrationConfiguration) -> MobileGuidanceCard {
        let needsAppGroup = configuration.isKeyboardExtensionEnabled
            || configuration.isShareExtensionEnabled
            || configuration.isActionExtensionEnabled
        return MobileGuidanceCard(
            id: "encrypted-app-group-store",
            surface: .iPhoneApp,
            severity: needsAppGroup ? .actionRequired : .optional,
            title: "Encrypted App Group store",
            detail: needsAppGroup
                ? "Enabled mobile extensions must use the shared encrypted App Group store rather than plaintext handoff files."
                : "App Group setup is only required when the signed app embeds keyboard, share, or action extensions.",
            isComplete: !needsAppGroup,
            actions: [
                MobileGuidanceAction(
                    id: "configure-app-group",
                    kind: .configureAppGroup,
                    title: "Configure App Group",
                    detail: "Use EncryptedSnapshotStore.appGroupStore(groupIdentifier:) from the signed app and extension targets.",
                    isPrimary: needsAppGroup
                )
            ]
        )
    }
}

public struct MobileIntegrationConfiguration: Codable, Equatable, Sendable {
    public var pastePermissionState: IOSPastePermissionState
    public var isKeyboardExtensionEnabled: Bool
    public var hasKeyboardFullAccess: Bool
    public var isShareExtensionEnabled: Bool
    public var isActionExtensionEnabled: Bool
    public var preferredSharePinboardID: UUID?
    public var lastPermissionGuidanceAt: Date?

    public init(
        pastePermissionState: IOSPastePermissionState = .unknown,
        isKeyboardExtensionEnabled: Bool = false,
        hasKeyboardFullAccess: Bool = false,
        isShareExtensionEnabled: Bool = false,
        isActionExtensionEnabled: Bool = false,
        preferredSharePinboardID: UUID? = nil,
        lastPermissionGuidanceAt: Date? = nil
    ) {
        self.pastePermissionState = pastePermissionState
        self.isKeyboardExtensionEnabled = isKeyboardExtensionEnabled
        self.hasKeyboardFullAccess = hasKeyboardFullAccess
        self.isShareExtensionEnabled = isShareExtensionEnabled
        self.isActionExtensionEnabled = isActionExtensionEnabled
        self.preferredSharePinboardID = preferredSharePinboardID
        self.lastPermissionGuidanceAt = lastPermissionGuidanceAt
    }

    public var enabledSurfaces: Set<MobileIntegrationSurface> {
        var surfaces: Set<MobileIntegrationSurface> = [.iPhoneApp, .iPadApp]
        if isKeyboardExtensionEnabled {
            surfaces.insert(.keyboardExtension)
        }
        if isShareExtensionEnabled {
            surfaces.insert(.shareExtension)
        }
        if isActionExtensionEnabled {
            surfaces.insert(.actionExtension)
        }
        return surfaces
    }

    public var browsingCapabilities: MobileBrowsingCapabilities {
        MobileBrowsingCapabilities()
    }

    public var keyboardCapabilities: MobileKeyboardExtensionCapabilities {
        MobileKeyboardExtensionCapabilities()
    }

    public var shareActionCapabilities: MobileShareActionExtensionCapabilities {
        MobileShareActionExtensionCapabilities()
    }

    public var onboardingSteps: [MobileOnboardingStep] {
        [
            MobileOnboardingStep(
                id: "paste-permission",
                title: "Allow Paste From Other Apps",
                detail: "Use iOS Settings to move PasteBuddy from Ask to Allow when automatic capture is desired.",
                isComplete: pastePermissionState == .allowed
            ),
            MobileOnboardingStep(
                id: "keyboard-full-access",
                title: "Keyboard Full Access",
                detail: "Enable only when the user wants the keyboard extension to read synced encrypted history.",
                isComplete: !isKeyboardExtensionEnabled || hasKeyboardFullAccess
            ),
            MobileOnboardingStep(
                id: "share-extension",
                title: "Share Extension",
                detail: "Enable the extension to save text, links, images, and files from the iOS Share sheet.",
                isComplete: isShareExtensionEnabled
            )
        ]
    }

    public var guidanceReport: MobileIntegrationGuidanceReport {
        MobileIntegrationGuidanceReport(configuration: self)
    }
}
