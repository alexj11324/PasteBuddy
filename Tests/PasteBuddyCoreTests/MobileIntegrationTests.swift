import UniformTypeIdentifiers
import XCTest
@testable import PasteBuddyCore
@testable import PasteBuddyMobile

@MainActor
final class MobileIntegrationTests: XCTestCase {
    func testMobileIntegrationConfigurationPersistsAndBuildsOnboardingSteps() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let guidanceDate = Date()
        let pinboardID = store.snapshot.pinboards[0].id

        store.setIOSPastePermissionState(.ask, guidanceShownAt: guidanceDate)
        store.setKeyboardExtensionEnabled(true, fullAccess: false)
        store.setShareExtensionEnabled(true)
        store.setActionExtensionEnabled(true)
        store.setPreferredMobileSharePinboard(pinboardID)

        XCTAssertEqual(store.snapshot.mobile.pastePermissionState, .ask)
        XCTAssertTrue(store.snapshot.mobile.enabledSurfaces.contains(.iPhoneApp))
        XCTAssertTrue(store.snapshot.mobile.enabledSurfaces.contains(.shareExtension))
        XCTAssertTrue(store.snapshot.mobile.enabledSurfaces.contains(.actionExtension))
        XCTAssertFalse(store.snapshot.mobile.onboardingSteps.first(where: { $0.id == "paste-permission" })?.isComplete ?? true)
        XCTAssertFalse(store.snapshot.mobile.onboardingSteps.first(where: { $0.id == "keyboard-full-access" })?.isComplete ?? true)
        XCTAssertTrue(store.mobileGuidanceReport.needsUserAction)
        XCTAssertFalse(store.mobileGuidanceReport.canAttemptAutomaticPasteCapture)
        XCTAssertTrue(store.mobileGuidanceReport.canUseManualExtensionImports)

        let reloaded = PasteBuddyStore(diskStore: harness.snapshotStore)
        reloaded.load()

        XCTAssertEqual(reloaded.snapshot.mobile.pastePermissionState, .ask)
        XCTAssertEqual(reloaded.snapshot.mobile.preferredSharePinboardID, pinboardID)
        XCTAssertTrue(reloaded.snapshot.mobile.isShareExtensionEnabled)
        let reloadedGuidanceDate = try XCTUnwrap(reloaded.snapshot.mobile.lastPermissionGuidanceAt)
        XCTAssertEqual(reloadedGuidanceDate.timeIntervalSince1970, guidanceDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMobileGuidanceDefaultsToLocalBrowsingWithoutRequiringPasteAccess() {
        let report = MobileIntegrationConfiguration().guidanceReport

        XCTAssertFalse(report.needsUserAction)
        XCTAssertFalse(report.canAttemptAutomaticPasteCapture)
        XCTAssertFalse(report.canUseManualExtensionImports)
        XCTAssertEqual(report.summary, "Mobile browsing is ready; optional extensions can be enabled later.")
        XCTAssertEqual(report.card(id: "ios-paste-permission")?.severity, .optional)
        XCTAssertEqual(report.card(id: "keyboard-extension")?.severity, .optional)
    }

    func testPastePermissionGuidanceExplainsAskToAllowWithoutDarkPatterns() {
        let configuration = MobileIntegrationConfiguration(pastePermissionState: .ask)
        let report = configuration.guidanceReport
        let guidance = report.pastePermissionGuidance

        XCTAssertEqual(guidance.automaticCaptureStatus, .needsUserConsent)
        XCTAssertEqual(guidance.title, "Allow Paste From Other Apps is set to Ask")
        XCTAssertTrue(guidance.shouldOfferSettingsAction)
        XCTAssertTrue(guidance.settingsPath.contains("Allow Paste From Other Apps"))
        XCTAssertTrue(guidance.detail.contains("only when the user wants automatic capture"))
        XCTAssertTrue(guidance.manualWorkflowMessage.contains("Manual workflows"))
        XCTAssertTrue(guidance.darkPatternGuardrail.contains("Do not block app launch"))
        XCTAssertEqual(report.card(id: "ios-paste-permission")?.actions.first?.detail, guidance.settingsPath)
        XCTAssertTrue(report.card(id: "ios-paste-permission")?.actions.contains {
            $0.kind == .continueManualImport
        } ?? false)
    }

    func testPastePermissionGuidanceKeepsDeniedManualAndAllowedAutomatic() {
        let denied = MobileIntegrationConfiguration(pastePermissionState: .denied).guidanceReport.pastePermissionGuidance

        XCTAssertEqual(denied.automaticCaptureStatus, .denied)
        XCTAssertTrue(denied.shouldOfferSettingsAction)
        XCTAssertTrue(denied.canUseManualWorkflows)
        XCTAssertTrue(denied.detail.contains("without blocking the app"))
        XCTAssertTrue(denied.manualWorkflowMessage.contains("Share extension imports"))

        let allowed = MobileIntegrationConfiguration(pastePermissionState: .allowed).guidanceReport.pastePermissionGuidance

        XCTAssertEqual(allowed.automaticCaptureStatus, .available)
        XCTAssertFalse(allowed.shouldOfferSettingsAction)
        XCTAssertTrue(allowed.detail.contains("local privacy rules still apply"))
    }

    func testMobileBrowsingCapabilitiesCoverNativeAppRequirementsAndLimitations() {
        let report = MobileIntegrationConfiguration().guidanceReport
        let capabilities = report.browsingCapabilities

        XCTAssertTrue(capabilities.canBrowseHistory)
        XCTAssertTrue(capabilities.canBrowsePinboards)
        XCTAssertTrue(capabilities.canSearchKeywords)
        XCTAssertEqual(capabilities.structuredFilterKinds, [.contentType, .sourceApp, .device, .date])
        XCTAssertTrue(capabilities.supportsFullScreenPreview)
        XCTAssertTrue(capabilities.supportsOriginalCopy)
        XCTAssertTrue(capabilities.supportsPlainTextCopy)
        XCTAssertTrue(capabilities.supportsContextMenus)
        XCTAssertTrue(capabilities.supportsPinboardDragAndDrop)
        XCTAssertEqual(
            Set(capabilities.iPadMultitaskingModes),
            Set([.stageManager, .splitView, .slideOver, .dragAndDrop])
        )
        XCTAssertTrue(capabilities.backgroundClipboardLimitation.contains("do not permit dependable continuous background clipboard monitoring"))
        XCTAssertEqual(report.card(id: "ipad-multitasking")?.severity, .ready)
        XCTAssertTrue(report.card(id: "ios-background-capture-limit")?.detail.contains("foreground permission") ?? false)
    }

    func testKeyboardCapabilitiesExplainFullAccessPrivacyAndIPadLayouts() {
        let configuration = MobileIntegrationConfiguration(
            isKeyboardExtensionEnabled: true,
            hasKeyboardFullAccess: false
        )
        let report = configuration.guidanceReport
        let capabilities = report.keyboardCapabilities

        XCTAssertTrue(capabilities.supportsGlobeSwitcherActivation)
        XCTAssertTrue(capabilities.canBrowseHistory)
        XCTAssertTrue(capabilities.canBrowsePinboards)
        XCTAssertTrue(capabilities.supportsTextInsertion)
        XCTAssertTrue(capabilities.supportsPlainTextCopy)
        XCTAssertTrue(capabilities.supportsDragAndDrop)
        XCTAssertTrue(capabilities.supportsLongPressActions)
        XCTAssertEqual(
            Set(capabilities.iPadLayoutModes),
            Set([.stageManager, .splitView, .slideOver, .dragAndDrop])
        )
        XCTAssertTrue(capabilities.fullAccessPrivacyExplanation.contains("shared App Group history"))
        XCTAssertTrue(capabilities.fullAccessPrivacyExplanation.contains("device or private iCloud"))
        XCTAssertEqual(report.card(id: "keyboard-extension")?.severity, .actionRequired)
        XCTAssertTrue(report.card(id: "keyboard-extension")?.detail.contains("Full Access") ?? false)
    }

    func testKeyboardPasteServiceInsertsPlainTextAndBlocksWithoutFullAccess() {
        var insertedText: [String] = []
        let service = MobileKeyboardPasteService { text in
            insertedText.append(text)
            return true
        }
        let item = ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Alex iPad",
            contentType: .text,
            title: "Saved Reply",
            payload: ClipboardPayload(text: "Thanks for the context.")
        )
        let readyConfiguration = MobileIntegrationConfiguration(
            isKeyboardExtensionEnabled: true,
            hasKeyboardFullAccess: true
        )

        let inserted = service.paste(item, format: .plainText, configuration: readyConfiguration)

        XCTAssertEqual(inserted.outcome, .insertedText)
        XCTAssertEqual(inserted.format, .plainText)
        XCTAssertEqual(inserted.characterCount, "Thanks for the context.".count)
        XCTAssertEqual(insertedText, ["Thanks for the context."])

        let limitedConfiguration = MobileIntegrationConfiguration(
            isKeyboardExtensionEnabled: true,
            hasKeyboardFullAccess: false
        )
        let blocked = service.paste(item, format: .plainText, configuration: limitedConfiguration)

        XCTAssertEqual(blocked.outcome, .fullAccessRequired)
        XCTAssertNotNil(blocked.fullAccessExplanation)
        XCTAssertTrue(blocked.statusMessage.contains("Full Access"))
        XCTAssertEqual(insertedText, ["Thanks for the context."])
    }

    func testShareActionCapabilitiesExplainSupportedInputsFavoritesAndFailures() {
        let configuration = MobileIntegrationConfiguration(
            isShareExtensionEnabled: true,
            isActionExtensionEnabled: true
        )
        let report = configuration.guidanceReport
        let capabilities = report.shareActionCapabilities

        XCTAssertEqual(capabilities.supportedContentTypes, [.text, .url, .image, .file])
        XCTAssertTrue(capabilities.canChooseTargetPinboard)
        XCTAssertTrue(capabilities.supportsShareExtension)
        XCTAssertTrue(capabilities.supportsActionExtension)
        XCTAssertTrue(capabilities.supportsShareSheetFavoritesAndReorder)
        XCTAssertTrue(capabilities.favoriteReorderGuidance.contains("Share sheet favorites"))
        XCTAssertTrue(capabilities.unsupportedInputExplanation.contains("Unsupported provider payloads"))
        XCTAssertEqual(report.card(id: "share-extension")?.severity, .ready)
        XCTAssertEqual(report.card(id: "action-extension")?.severity, .ready)
        XCTAssertEqual(
            MobileItemProviderAdapterError.unsupportedContent.localizedDescription,
            "The shared content did not include text, a URL, a file URL, or image data."
        )
    }

    func testShareActionExtensionServiceImportsMultipleProvidersIntoSelectedPinboard() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id

        let textProvider = NSItemProvider()
        textProvider.suggestedName = "Shared Selection"
        textProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("Shared selection body".utf8), nil)
            return nil
        }

        let imageProvider = NSItemProvider()
        imageProvider.suggestedName = "Shared Screenshot"
        imageProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.image.identifier,
            visibility: .all
        ) { completion in
            completion(Data([0x89, 0x50, 0x4e, 0x47]), nil)
            return nil
        }

        let result = try await MobileShareActionExtensionService.importSupportedContent(
            from: [textProvider, imageProvider],
            into: store,
            configuration: MobileItemProviderImportConfiguration(
                preferredPinboardID: pinboardID,
                source: .shareExtension,
                deviceName: "Test iPhone"
            )
        )

        XCTAssertEqual(result.importedItems.count, 2)
        XCTAssertEqual(result.targetPinboardID, pinboardID)
        XCTAssertEqual(result.source, .shareExtension)
        XCTAssertTrue(result.statusMessage.contains("selected pinboard"))
        XCTAssertEqual(Set(store.snapshot.pinboards[0].itemIDs), Set(result.importedItems.map(\.id)))
        XCTAssertEqual(store.snapshot.items.map(\.sourceAppName), ["PasteBuddy Share Extension", "PasteBuddy Share Extension"])
        XCTAssertEqual(store.snapshot.items.first?.contentType, .image)
        XCTAssertEqual(store.snapshot.items.last?.contentType, .text)
    }

    func testItemProviderAdapterTreatsFileURLAsFileBeforeGenericURL() async throws {
        let fileURL = URL(fileURLWithPath: "/Users/example/Documents/Report.pdf")
        let provider = NSItemProvider(object: fileURL as NSURL)

        let input = try await MobileItemProviderAdapter.firstSupportedInput(from: [provider])

        XCTAssertEqual(input.fileURLString, fileURL.absoluteString)
        XCTAssertNil(input.urlString)
    }

    func testShareActionExtensionResultUsesStoredPreferredPinboard() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        store.setPreferredMobileSharePinboard(pinboardID)

        let textProvider = NSItemProvider()
        textProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("Stored mobile target".utf8), nil)
            return nil
        }

        let result = try await MobileShareActionExtensionService.importSupportedContent(
            from: [textProvider],
            into: store
        )

        XCTAssertEqual(result.importedItems.count, 1)
        XCTAssertEqual(result.targetPinboardID, pinboardID)
        XCTAssertTrue(result.statusMessage.contains("selected pinboard"))
        XCTAssertTrue(store.snapshot.pinboards[0].itemIDs.contains(result.importedItems[0].id))
    }

    func testShareActionImportResultUsesLocalizedSingularAndPluralMessages() {
        let item = ClipboardItem(
            sourceAppName: "Share",
            deviceName: "Test iPhone",
            contentType: .text,
            title: "Shared text",
            payload: ClipboardPayload(text: "Shared text")
        )
        let singular = MobileShareActionImportResult(
            importedItems: [item],
            targetPinboardID: nil,
            source: .shareExtension
        )
        let plural = MobileShareActionImportResult(
            importedItems: [item, item],
            targetPinboardID: UUID(),
            source: .shareExtension
        )

        XCTAssertEqual(singular.statusMessage, "Saved 1 item to history.")
        XCTAssertEqual(plural.statusMessage, "Saved 2 items to history and selected pinboard.")
        XCTAssertFalse(singular.statusMessage.contains("item(s)"))
        XCTAssertFalse(plural.statusMessage.contains("item(s)"))
    }

    func testShareActionExtensionResultDoesNotReportMissingPinboardTarget() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let missingPinboardID = UUID()

        let textProvider = NSItemProvider()
        textProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("Missing mobile target".utf8), nil)
            return nil
        }

        let result = try await MobileShareActionExtensionService.importSupportedContent(
            from: [textProvider],
            into: store,
            configuration: MobileItemProviderImportConfiguration(preferredPinboardID: missingPinboardID)
        )

        XCTAssertNil(result.targetPinboardID)
        XCTAssertFalse(result.statusMessage.contains("selected pinboard"))
        XCTAssertTrue(store.snapshot.pinboards[0].itemIDs.isEmpty)
    }

    func testMobileBrowsingSearchAndStructuredFiltersCoverSourceDeviceAndType() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let iPadDesign = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Freeform",
            deviceName: "Alex iPad",
            contentType: .image,
            title: "Launch Board Screenshot",
            payload: ClipboardPayload(imageData: Data([0x01]), ocrText: "wireframe launch notes")
        ))
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Safari",
            deviceName: "Alex iPhone",
            contentType: .url,
            title: "Paste Help",
            payload: ClipboardPayload(urlString: "https://pasteapp.io/help/paste-on-ipad")
        ))

        XCTAssertTrue(store.filterSuggestions(matching: "free").contains {
            $0.kind == .sourceApp && $0.value == "Freeform"
        })
        XCTAssertTrue(store.filterSuggestions(matching: "ipad").contains {
            $0.kind == .device && $0.value == "Alex iPad"
        })

        store.searchQuery = "wireframe"
        store.contentTypeFilter = .image
        store.sourceAppFilter = "Freeform"
        store.deviceFilter = "Alex iPad"

        XCTAssertEqual(store.filteredItems.map(\.id), [iPadDesign.id])
        XCTAssertEqual(store.activeFilterSummaries.map(\.kind), [.contentType, .sourceApp, .device])
    }

    func testMobileGuidanceExplainsAskPermissionAndFullAccessWithoutBlockingManualImports() {
        let configuration = MobileIntegrationConfiguration(
            pastePermissionState: .ask,
            isKeyboardExtensionEnabled: true,
            hasKeyboardFullAccess: false,
            isShareExtensionEnabled: true,
            isActionExtensionEnabled: true
        )

        let report = configuration.guidanceReport

        XCTAssertTrue(report.needsUserAction)
        XCTAssertFalse(report.canAttemptAutomaticPasteCapture)
        XCTAssertTrue(report.canUseManualExtensionImports)
        XCTAssertEqual(report.summary, "Mobile setup needs 3 actions.")
        XCTAssertEqual(report.card(id: "ios-paste-permission")?.severity, .actionRequired)
        XCTAssertEqual(report.card(id: "keyboard-extension")?.severity, .actionRequired)
        XCTAssertEqual(report.card(id: "share-extension")?.severity, .ready)
        XCTAssertEqual(report.card(id: "action-extension")?.severity, .ready)
        XCTAssertEqual(report.card(id: "app-group-store")?.severity, .actionRequired)
        XCTAssertTrue(report.card(id: "ios-paste-permission")?.actions.contains {
            $0.kind == .continueManualImport
        } ?? false)
    }

    func testMobileGuidanceKeepsDeniedPasteAccessNonFatalForShareExtensionImports() {
        let configuration = MobileIntegrationConfiguration(
            pastePermissionState: .denied,
            isShareExtensionEnabled: true
        )

        let report = configuration.guidanceReport

        XCTAssertTrue(report.needsUserAction)
        XCTAssertFalse(report.canAttemptAutomaticPasteCapture)
        XCTAssertTrue(report.canUseManualExtensionImports)
        XCTAssertEqual(report.card(id: "ios-paste-permission")?.title, "Paste access is denied")
        XCTAssertTrue(report.card(id: "ios-paste-permission")?.detail.contains("must not treat denial as fatal") ?? false)
        XCTAssertEqual(report.card(id: "share-extension")?.severity, .ready)
    }

    func testSharedContentImportPinsSharedTextAndBlocksSensitiveText() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let pinboardID = store.snapshot.pinboards[0].id
        store.setPreferredMobileSharePinboard(pinboardID)

        let service = SharedContentImportService()
        let imported = try service.importContent(
            SharedContentInput(
                title: "Shared Note",
                text: "Research link summary",
                source: .shareExtension,
                deviceName: "Test iPhone"
            ),
            into: store
        )

        XCTAssertEqual(imported.title, "Shared Note")
        XCTAssertEqual(imported.sourceAppName, "PasteBuddy Share Extension")
        XCTAssertEqual(store.snapshot.pinboards[0].itemIDs, [imported.id])

        store.toggleSensitiveTextBlocking()
        XCTAssertThrowsError(try service.importContent(
            SharedContentInput(
                text: "api_key = sk_live_51ABCDEF0123456789",
                source: .actionExtension,
                deviceName: "Test iPhone"
            ),
            into: store
        )) { error in
            XCTAssertEqual(error as? SharedContentImportError, .sensitiveTextBlocked)
        }
    }

    func testSharedContentImportRespectsCustomCaptureRules() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        _ = store.addCaptureRule(
            name: "No private browser shares",
            condition: .sourceBundleIdentifier,
            pattern: "com.example.private-browser"
        )
        let service = SharedContentImportService()

        XCTAssertThrowsError(try service.importContent(
            SharedContentInput(
                title: "Private Tab",
                urlString: "https://example.com/private",
                source: .shareExtension,
                sourceBundleIdentifier: "com.example.private-browser",
                deviceName: "Test iPhone"
            ),
            into: store
        )) { error in
            XCTAssertEqual(error as? SharedContentImportError, .captureRuleBlocked("No private browser shares"))
        }

        XCTAssertTrue(store.snapshot.items.isEmpty)
    }

    func testSharedImageImportMarksOCRPendingWhenLocalOCRIsEnabled() throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = PasteBuddyStore(diskStore: harness.snapshotStore)
        let service = SharedContentImportService()

        let imported = try service.importContent(
            SharedContentInput(
                title: "Shared Screenshot",
                imageData: Data([0x01, 0x02, 0x03]),
                source: .iPadApp,
                deviceName: "Test iPad"
            ),
            into: store
        )

        XCTAssertEqual(imported.contentType, .image)
        if case .pending = imported.ocrState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected OCR to be pending after shared image import.")
        }
    }

    func testItemProviderAdapterCreatesInputsForShareExtensions() async throws {
        let textProvider = NSItemProvider()
        textProvider.suggestedName = "Shared Text"
        textProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("Shared from Safari".utf8), nil)
            return nil
        }

        let textInput = try await MobileItemProviderAdapter.firstSupportedInput(
            from: [textProvider],
            configuration: MobileItemProviderImportConfiguration(
                source: .shareExtension,
                deviceName: "Test iPhone"
            )
        )

        XCTAssertEqual(textInput.title, "Shared Text")
        XCTAssertEqual(textInput.text, "Shared from Safari")
        XCTAssertEqual(textInput.source, .shareExtension)
        XCTAssertEqual(textInput.deviceName, "Test iPhone")

        let urlProvider = NSItemProvider()
        urlProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.url.identifier,
            visibility: .all
        ) { completion in
            completion(Data("https://example.com/article".utf8), nil)
            return nil
        }

        let urlInput = try await MobileItemProviderAdapter.firstSupportedInput(
            from: [urlProvider],
            configuration: MobileItemProviderImportConfiguration(source: .actionExtension)
        )

        XCTAssertEqual(urlInput.urlString, "https://example.com/article")
        XCTAssertEqual(urlInput.source, .actionExtension)
    }

    func testItemProviderAdapterRejectsEmptyOrUnsupportedInput() async {
        await XCTAssertThrowsErrorAsync(
            try await MobileItemProviderAdapter.firstSupportedInput(from: [])
        ) { error in
            XCTAssertEqual(error as? MobileItemProviderAdapterError, .emptyProviders)
        }

        let unsupportedProvider = NSItemProvider()
        unsupportedProvider.registerDataRepresentation(
            forTypeIdentifier: "com.example.unsupported",
            visibility: .all
        ) { completion in
            completion(Data([0x01]), nil)
            return nil
        }

        await XCTAssertThrowsErrorAsync(
            try await MobileItemProviderAdapter.firstSupportedInput(from: [unsupportedProvider])
        ) { error in
            XCTAssertEqual(error as? MobileItemProviderAdapterError, .unsupportedContent)
        }
    }

    func testAppGroupStoreUsesPasteBuddyEncryptedStorePathWhenContainerIsAvailable() throws {
        do {
            let store = try EncryptedSnapshotStore.appGroupStore(groupIdentifier: "group.com.example.PasteBuddy.tests")

            XCTAssertEqual(store.fileURL.lastPathComponent, "clipboard.pbenc")
            XCTAssertEqual(store.fileURL.deletingLastPathComponent().lastPathComponent, "PasteBuddy")
        } catch {
            guard case .missingAppGroupContainer(let groupIdentifier) = error as? SnapshotStoreError else {
                return XCTFail("Expected app group store or missing app group container error.")
            }
            XCTAssertEqual(groupIdentifier, "group.com.example.PasteBuddy.tests")
        }
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @MainActor @autoclosure () async throws -> T,
    _ handler: @MainActor (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        handler(error)
    }
}
