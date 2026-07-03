import Foundation

private func localized(_ key: String, defaultValue: String) -> String {
    PasteBuddyLocalization.string(key, defaultValue: defaultValue)
}

private func localizedFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
    String(
        format: localized(key, defaultValue: defaultValue),
        locale: Locale.current,
        arguments: arguments
    )
}

public enum MobileIntegrationSurface: String, CaseIterable, Codable, Identifiable, Sendable {
    case iPhoneApp
    case iPadApp
    case keyboardExtension
    case shareExtension
    case actionExtension

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iPhoneApp: localized("mobile.surface.iphone_app", defaultValue: "iPhone App")
        case .iPadApp: localized("mobile.surface.ipad_app", defaultValue: "iPad App")
        case .keyboardExtension: localized("mobile.surface.keyboard_extension", defaultValue: "Keyboard Extension")
        case .shareExtension: localized("mobile.surface.share_extension", defaultValue: "Share Extension")
        case .actionExtension: localized("mobile.surface.action_extension", defaultValue: "Action Extension")
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
        case .stageManager: localized("mobile.ipad_mode.stage_manager", defaultValue: "Stage Manager")
        case .splitView: localized("mobile.ipad_mode.split_view", defaultValue: "Split View")
        case .slideOver: localized("mobile.ipad_mode.slide_over", defaultValue: "Slide Over")
        case .dragAndDrop: localized("mobile.ipad_mode.drag_and_drop", defaultValue: "Drag and Drop")
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
        backgroundClipboardLimitation: String = PasteBuddyLocalization.string("mobile.background_clipboard_limitation", defaultValue: "iOS and iPadOS do not permit dependable continuous background clipboard monitoring. PasteBuddy should browse synced or manually imported history, read the pasteboard only after foreground permission, and rely on Share or Action extensions for manual imports.")
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
        fullAccessPrivacyExplanation: String = PasteBuddyLocalization.string("mobile.keyboard.full_access_privacy_explanation", defaultValue: "Full Access lets the keyboard read PasteBuddy's shared App Group history and insert selected text. Clipboard data stays on the user's device or private iCloud account unless the user explicitly enables sync or sharing.")
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
        unsupportedInputExplanation: String = PasteBuddyLocalization.string("mobile.share_action.unsupported_input_explanation", defaultValue: "PasteBuddy can save shared text, links, images, and supported file URLs. Unsupported provider payloads should fail with a clear message and no plaintext temporary files."),
        favoriteReorderGuidance: String = PasteBuddyLocalization.string("mobile.share_action.favorite_reorder_guidance", defaultValue: "Users can add Save to PasteBuddy and Copy to PasteBuddy to iOS Share sheet favorites and reorder them from the system Share sheet edit screen.")
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
        case .unknown: localized("mobile.permission_state.unknown", defaultValue: "Unknown")
        case .ask: localized("mobile.permission_state.ask", defaultValue: "Ask")
        case .allowed: localized("mobile.permission_state.allowed", defaultValue: "Allowed")
        case .denied: localized("mobile.permission_state.denied", defaultValue: "Denied")
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
        case .ready: localized("mobile.guidance_severity.ready", defaultValue: "Ready")
        case .optional: localized("mobile.guidance_severity.optional", defaultValue: "Optional")
        case .actionRequired: localized("mobile.guidance_severity.action_required", defaultValue: "Action Required")
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
        case .openAppSettings: localized("mobile.guidance_action.open_app_settings", defaultValue: "Open App Settings")
        case .openKeyboardSettings: localized("mobile.guidance_action.open_keyboard_settings", defaultValue: "Open Keyboard Settings")
        case .enableShareExtension: localized("mobile.guidance_action.enable_share_extension", defaultValue: "Enable Share Extension")
        case .enableActionExtension: localized("mobile.guidance_action.enable_action_extension", defaultValue: "Enable Action Extension")
        case .configureAppGroup: localized("mobile.guidance_action.configure_app_group", defaultValue: "Configure App Group")
        case .continueManualImport: localized("mobile.guidance_action.continue_manual_import", defaultValue: "Continue Manual Import")
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
        case .available: localized("mobile.automatic_capture.available", defaultValue: "Available")
        case .needsUserConsent: localized("mobile.automatic_capture.needs_user_consent", defaultValue: "Needs User Consent")
        case .denied: localized("mobile.automatic_capture.denied", defaultValue: "Denied")
        case .explainFirst: localized("mobile.automatic_capture.explain_first", defaultValue: "Explain First")
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
        self.settingsPath = localized(
            "mobile.paste_permission.settings_path",
            defaultValue: "Settings > Apps > PasteBuddy > Allow Paste From Other Apps > Allow"
        )
        self.canUseManualWorkflows = true
        self.manualWorkflowMessage = localized(
            "mobile.paste_permission.manual_workflows_remain_available",
            defaultValue: "Manual workflows remain available: browsing synced history, keyboard access, Share extension imports, and Action extension imports continue when automatic pasteboard capture is not allowed."
        )
        self.darkPatternGuardrail = localized(
            "mobile.paste_permission.dark_pattern_guardrail",
            defaultValue: "Do not block app launch, hide manual workflows, or imply clipboard data leaves the device/iCloud to pressure the user into enabling Allow."
        )

        switch configuration.pastePermissionState {
        case .allowed:
            self.automaticCaptureStatus = .available
            self.title = localized("mobile.paste_permission.allowed.title", defaultValue: "Automatic capture is allowed")
            self.detail = localized(
                "mobile.paste_permission.allowed.detail",
                defaultValue: "PasteBuddy may read pasteboard content after foreground user activity and local privacy rules still apply before anything is saved."
            )
            self.shouldOfferSettingsAction = false
        case .ask:
            self.automaticCaptureStatus = .needsUserConsent
            self.title = localized("mobile.paste_permission.ask.title", defaultValue: "Allow Paste From Other Apps is set to Ask")
            self.detail = localized(
                "mobile.paste_permission.ask.detail",
                defaultValue: "iOS will ask before PasteBuddy reads pasteboard content. Offer the Settings path only when the user wants automatic capture."
            )
            self.shouldOfferSettingsAction = true
        case .denied:
            self.automaticCaptureStatus = .denied
            self.title = localized("mobile.paste_permission.denied.title", defaultValue: "Paste access is denied")
            self.detail = localized(
                "mobile.paste_permission.denied.detail",
                defaultValue: "Automatic pasteboard capture is disabled. PasteBuddy should keep manual workflows available and offer Settings without blocking the app."
            )
            self.shouldOfferSettingsAction = true
        case .unknown:
            self.automaticCaptureStatus = .explainFirst
            self.title = localized("mobile.paste_permission.unknown.title", defaultValue: "Paste permission has not been checked")
            self.detail = localized(
                "mobile.paste_permission.unknown.detail",
                defaultValue: "Explain why iOS asks before reading pasteboard content before attempting automatic capture."
            )
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
            let count = cards.filter { $0.severity == .actionRequired }.count
            if count == 1 {
                return localized("mobile.summary.needs_one_action", defaultValue: "Mobile setup needs 1 action.")
            }
            return localizedFormat("mobile.summary.needs_actions", defaultValue: "Mobile setup needs %d actions.", count)
        }
        if cards.contains(where: { $0.severity == .optional }) {
            return localized(
                "mobile.summary.ready_optional_extensions",
                defaultValue: "Mobile browsing is ready; optional extensions can be enabled later."
            )
        }
        return localized("mobile.summary.ready_all", defaultValue: "Mobile browsing and extensions are ready.")
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
            title: localized("mobile.card.ipad_multitasking.title", defaultValue: "iPad browsing adapts to multitasking"),
            detail: localized(
                "mobile.card.ipad_multitasking.detail",
                defaultValue: "The native mobile browser uses an adaptive split layout for portrait, landscape, Stage Manager, Split View, Slide Over, and drag-and-drop into pinboards."
            ),
            isComplete: true
        )
    }

    private static func backgroundCaptureLimitCard() -> MobileGuidanceCard {
        MobileGuidanceCard(
            id: "ios-background-capture-limit",
            surface: .iPhoneApp,
            severity: .ready,
            title: localized("mobile.card.background_capture_limit.title", defaultValue: "Background clipboard capture is limited"),
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
                title: localized("mobile.card.paste_access_allowed.title", defaultValue: "Paste access is allowed"),
                detail: guidance.detail,
                isComplete: true,
                actions: [
                    MobileGuidanceAction(
                        id: "review-app-settings",
                        kind: .openAppSettings,
                        title: localized("mobile.action.review_app_settings.title", defaultValue: "Review App Settings"),
                        detail: localized(
                            "mobile.action.review_app_settings.detail",
                            defaultValue: "Use the iOS app target to open PasteBuddy settings when the user wants to change paste access."
                        )
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
                        title: localized("mobile.action.open_pastebuddy_settings.title", defaultValue: "Open PasteBuddy Settings"),
                        detail: guidance.settingsPath,
                        isPrimary: true
                    ),
                    MobileGuidanceAction(
                        id: "continue-manual-import",
                        kind: .continueManualImport,
                        title: localized("mobile.action.use_manual_import.title", defaultValue: "Use Manual Import"),
                        detail: localized(
                            "mobile.action.use_manual_import.detail",
                            defaultValue: "Share and Action extensions can still save selected content without automatic pasteboard reads."
                        )
                    )
                ]
            )
        case .denied:
            return MobileGuidanceCard(
                id: "ios-paste-permission",
                surface: .iPhoneApp,
                severity: .actionRequired,
                title: guidance.title,
                detail: "\(guidance.detail) \(localized("mobile.paste_permission.denial_not_fatal", defaultValue: "PasteBuddy must not treat denial as fatal.")) \(guidance.manualWorkflowMessage)",
                isComplete: false,
                actions: [
                    MobileGuidanceAction(
                        id: "open-app-settings",
                        kind: .openAppSettings,
                        title: localized("mobile.action.open_pastebuddy_settings.title", defaultValue: "Open PasteBuddy Settings"),
                        detail: guidance.settingsPath,
                        isPrimary: true
                    ),
                    MobileGuidanceAction(
                        id: "continue-manual-import",
                        kind: .continueManualImport,
                        title: localized("mobile.action.continue_without_automatic_capture.title", defaultValue: "Continue Without Automatic Capture"),
                        detail: localized(
                            "mobile.action.continue_without_automatic_capture.detail",
                            defaultValue: "Use Share or Action extension imports while paste access remains denied."
                        )
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
                        title: localized("mobile.action.prepare_settings_guidance.title", defaultValue: "Prepare Settings Guidance"),
                        detail: localized(
                            "mobile.action.prepare_settings_guidance.detail",
                            defaultValue: "Show the settings path when the user opts into automatic capture."
                        )
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
                title: localized("mobile.card.keyboard_optional.title", defaultValue: "Keyboard extension is optional"),
                detail: localized(
                    "mobile.card.keyboard_optional.detail",
                    defaultValue: "Users can browse the main iOS app without enabling the custom keyboard. When enabled, PasteBuddy appears from the globe keyboard switcher."
                ),
                isComplete: false,
                actions: [
                    MobileGuidanceAction(
                        id: "open-keyboard-settings",
                        kind: .openKeyboardSettings,
                        title: localized("mobile.action.enable_keyboard_later.title", defaultValue: "Enable Keyboard Later"),
                        detail: localized(
                            "mobile.action.enable_keyboard_later.detail",
                            defaultValue: "Add PasteBuddy from iOS Keyboard settings when in-app paste access is needed."
                        )
                    )
                ]
            )
        }

        if configuration.hasKeyboardFullAccess {
            return MobileGuidanceCard(
                id: "keyboard-extension",
                surface: .keyboardExtension,
                severity: .ready,
                title: localized("mobile.card.keyboard_full_access_enabled.title", defaultValue: "Keyboard Full Access is enabled"),
                detail: configuration.keyboardCapabilities.fullAccessPrivacyExplanation,
                isComplete: true
            )
        }

        return MobileGuidanceCard(
            id: "keyboard-extension",
            surface: .keyboardExtension,
            severity: .actionRequired,
            title: localized("mobile.card.keyboard_full_access_needed.title", defaultValue: "Keyboard Full Access is needed"),
            detail: localizedFormat(
                "mobile.card.keyboard_full_access_needed.detail",
                defaultValue: "Without Full Access, the keyboard should stay in limited mode and avoid claiming it can read synced history. %@",
                configuration.keyboardCapabilities.fullAccessPrivacyExplanation
            ),
            isComplete: false,
            actions: [
                MobileGuidanceAction(
                    id: "open-keyboard-settings",
                    kind: .openKeyboardSettings,
                    title: localized("mobile.guidance_action.open_keyboard_settings", defaultValue: "Open Keyboard Settings"),
                    detail: localized(
                        "mobile.action.open_keyboard_settings.detail",
                        defaultValue: "Enable Full Access only after explaining that the keyboard reads PasteBuddy's shared history."
                    ),
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
            title: configuration.isShareExtensionEnabled
                ? localized("mobile.card.share_extension_enabled.title", defaultValue: "Share extension is enabled")
                : localized("mobile.card.share_extension_available.title", defaultValue: "Share extension is available"),
            detail: configuration.isShareExtensionEnabled
                ? localizedFormat(
                    "mobile.card.share_extension_enabled.detail",
                    defaultValue: "Selected text, URLs, images, and files can be saved into history or a selected pinboard. %@",
                    configuration.shareActionCapabilities.favoriteReorderGuidance
                )
                : localizedFormat(
                    "mobile.card.share_extension_available.detail",
                    defaultValue: "Enable the Share extension when users want to save content from other apps without automatic pasteboard capture. %@",
                    configuration.shareActionCapabilities.favoriteReorderGuidance
                ),
            isComplete: configuration.isShareExtensionEnabled,
            actions: configuration.isShareExtensionEnabled ? [] : [
                MobileGuidanceAction(
                    id: "enable-share-extension",
                    kind: .enableShareExtension,
                    title: localized("mobile.guidance_action.enable_share_extension", defaultValue: "Enable Share Extension"),
                    detail: localized("mobile.action.enable_share_extension.detail", defaultValue: "Add PasteBuddy to the iOS Share sheet favorites."),
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
            title: configuration.isActionExtensionEnabled
                ? localized("mobile.card.action_extension_enabled.title", defaultValue: "Action extension is enabled")
                : localized("mobile.card.action_extension_available.title", defaultValue: "Action extension is available"),
            detail: configuration.isActionExtensionEnabled
                ? localized("mobile.card.action_extension_enabled.detail", defaultValue: "The action extension can save supported selections directly into history or the preferred pinboard.")
                : localized("mobile.card.action_extension_available.detail", defaultValue: "Enable the action extension for one-tap Copy to PasteBuddy actions in compatible apps."),
            isComplete: configuration.isActionExtensionEnabled,
            actions: configuration.isActionExtensionEnabled ? [] : [
                MobileGuidanceAction(
                    id: "enable-action-extension",
                    kind: .enableActionExtension,
                    title: localized("mobile.guidance_action.enable_action_extension", defaultValue: "Enable Action Extension"),
                    detail: localized("mobile.action.enable_action_extension.detail", defaultValue: "Expose PasteBuddy as a reusable iOS action."),
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
            id: "app-group-store",
            surface: .iPhoneApp,
            severity: needsAppGroup ? .actionRequired : .optional,
            title: localized("mobile.card.app_group.title", defaultValue: "App Group store"),
            detail: needsAppGroup
                ? localized("mobile.card.app_group.needs.detail", defaultValue: "Enabled mobile extensions must use the shared App Group store rather than plaintext handoff files.")
                : localized("mobile.card.app_group.optional.detail", defaultValue: "App Group setup is only required when the signed app embeds keyboard, share, or action extensions."),
            isComplete: !needsAppGroup,
            actions: [
                MobileGuidanceAction(
                    id: "configure-app-group",
                    kind: .configureAppGroup,
                    title: localized("mobile.guidance_action.configure_app_group", defaultValue: "Configure App Group"),
                    detail: localized(
                        "mobile.action.configure_app_group.detail",
                        defaultValue: "Use the shared App Group store from the signed app and extension targets."
                    ),
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
                title: localized(
                    "mobile.onboarding.allow_paste_from_other_apps.title",
                    defaultValue: "Allow Paste From Other Apps"
                ),
                detail: localized(
                    "mobile.onboarding.allow_paste_from_other_apps.detail",
                    defaultValue: "Use iOS Settings to move PasteBuddy from Ask to Allow when automatic capture is desired."
                ),
                isComplete: pastePermissionState == .allowed
            ),
            MobileOnboardingStep(
                id: "keyboard-full-access",
                title: localized("mobile.onboarding.keyboard_full_access.title", defaultValue: "Keyboard Full Access"),
                detail: localized(
                    "mobile.onboarding.keyboard_full_access.detail",
                    defaultValue: "Enable only when the user wants the keyboard extension to read synced history."
                ),
                isComplete: !isKeyboardExtensionEnabled || hasKeyboardFullAccess
            ),
            MobileOnboardingStep(
                id: "share-extension",
                title: localized("mobile.onboarding.share_extension.title", defaultValue: "Share Extension"),
                detail: localized(
                    "mobile.onboarding.share_extension.detail",
                    defaultValue: "Enable the extension to save text, links, images, and files from the iOS Share sheet."
                ),
                isComplete: isShareExtensionEnabled
            )
        ]
    }

    public var guidanceReport: MobileIntegrationGuidanceReport {
        MobileIntegrationGuidanceReport(configuration: self)
    }
}
