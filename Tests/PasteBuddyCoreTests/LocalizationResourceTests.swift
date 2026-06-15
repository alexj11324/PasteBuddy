import Foundation
@testable import PasteBuddyCore
import XCTest

final class LocalizationResourceTests: XCTestCase {
    func testEnglishAndSimplifiedChineseResourcesHaveMatchingKeys() throws {
        let english = try localizedStrings(locale: "en")
        let simplifiedChinese = try localizedStrings(locale: "zh-Hans")

        XCTAssertEqual(Set(english.keys), Set(simplifiedChinese.keys))
    }

    func testPriorityUserFacingStringsHaveSimplifiedChineseTranslations() throws {
        let simplifiedChinese = try localizedStrings(locale: "zh-Hans")
        let priorityKeys = [
            "Search clipboard",
            "New Text Item",
            "Labels",
            "Save Labels",
            "Clipboard item labels",
            "Reusable Type",
            "Code",
            "Color",
            "Template",
            "Asset",
            "Custom Capture Rules",
            "Add Rule",
            "Rule Pattern",
            "Contains Text",
            "Source Bundle ID",
            "Paste Stack",
            "Delete Pinboard?",
            "Items stay in clipboard history. Only this pinboard collection is removed.",
            "Drop clipboard items here to pin them.",
            "Share Pinboard",
            "Share Settings",
            "Access Mode",
            "Default Permission",
            "Invite Participant",
            "Participants",
            "Stop Sharing",
            "Read Only",
            "Can Edit",
            "Invitation Only",
            "Link Access",
            "Collecting",
            "Paused",
            "Next",
            "Top to Bottom",
            "Bottom to Top",
            "Copy as Plain Text",
            "Paste to Active App",
            "Paste Order",
            "Multiple selected items paste as plain text in this visible order, keeping mixed content predictable.",
            "Clear Filters",
            "Active clipboard filters",
            "Run local Apple OCR after image capture",
            "Enable local MCP server access",
            "Clear MCP Audit Log",
            "Sync & Sharing",
            "Request Accessibility Access",
            "Last Direct Paste",
            "Dismiss",
            "Clear Shortcut",
            "Key",
            "Quick Paste Modifiers",
            "Plain Text Quick Paste Modifiers",
            "Save to PasteBuddy",
            "Mobile Setup",
            "Restore Purchases",
            "Storage Security",
            "Estimated History Size",
            "Pinned History Size",
            "Unpinned History Size",
            "Storage Limit",
            "Clear All History Including Pinned Items",
            "Device Unlock",
            "Trial",
            "Quality Bar",
            "Supported Locales",
            "Manual Release Audit",
            "VoiceOver",
            "Larger Text",
            "Appearance",
            "Not Color Only",
            "Localization",
            "Implemented",
            "Manual Audit Required",
            "Encrypt clipboard history at rest",
            "Require Touch ID to unlock history",
            "Unlock History",
            "Lock History",
            "History Lock",
            "Standard Local Storage",
            "Encrypted Local Storage",
            "Confirm Action",
            "Clear Unpinned History?",
            "Clear All History?",
            "Revoke MCP Access?",
            "Clear MCP Audit Log?",
            "This removes all local clipboard history, including pinned item memberships. This action cannot be undone.",
            "Storage",
            "Plans",
            "Integrations",
            "More",
            "Clipboard Shelf",
            "Content type filter",
            "Source app filter",
            "Device filter",
            "Copied date filter",
            "Removes all active clipboard filters.",
            "Move to %@",
            "Pin to %@",
            "Touch ID grace period: %d seconds",
            "Keep up to %d items",
            "Use up to %@",
            "Keep history forever",
            "Keep normal history for %d days",
            "Clipboard details, OCR text, and pinning actions appear here.",
            "Separate labels with commas.",
            "Remove label %@",
            "Saves edits back to clipboard history.",
            "Start Collecting",
            "Stop Collecting",
            "Paste Stack (%d)",
            "Pinboard %@",
            "Color %@",
            "Pinboard color %@",
            "Selected",
            "Not selected",
            "No external app is available to exclude.",
            "Excluded %@.",
            "PasteBuddy could not create this item.",
            "Resumes at %@.",
            "PasteBuddy clipboard shelf",
            "Reload clipboard history",
            "Add item or pinboard",
            "More actions",
            "New copies will appear here.",
            "Start collecting copied items.",
            "Copy text, links, screenshots, or files to fill the shelf.",
            "Stop Paste Stack",
            "Start Paste Stack",
            "Reverse Paste Stack",
            "Show Clipboard Shelf",
            "Show/Hide Clipboard Shelf",
            "Open PasteBuddy",
            "Open Settings",
            "%@ Settings",
            "Disable Launch at Login",
            "Enable Launch at Login",
            "Launch at Login: On",
            "Launch at Login: Off",
            "PasteBuddy Active",
            "PasteBuddy Paused",
            "Pause Capture for 15 Minutes",
            "Pause Capture for 1 Hour",
            "Pause Capture",
            "Link",
            "Double-click or press Return to paste.",
            "%d file",
            "%d files",
            "%d chars",
            "Not needed",
            "OCR pending",
            "OCR complete",
            "OCR failed",
            "Capture active",
            "Capture paused",
            "Capture paused temporarily",
            "New clipboard content is evaluated by local privacy rules before it enters encrypted history.",
            "Automatic clipboard capture is stopped until you resume it.",
            "Automatic clipboard capture is stopped until the selected resume time."
        ]

        for key in priorityKeys {
            let translation = try XCTUnwrap(simplifiedChinese[key], "Missing translation for \(key)")
            XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(translation, key)
        }
    }

    func testAccessibilityLocalizationQualityReportCoversReleaseCriteria() {
        let report = AccessibilityLocalizationQualityReport()

        XCTAssertFalse(report.hasReleaseBlockers)
        XCTAssertEqual(report.supportedLocaleIdentifiers, ["en", "zh-Hans"])
        XCTAssertEqual(Set(report.findings.map(\.area)), Set(AccessibilityQualityArea.allCases))
        XCTAssertTrue(report.summary.contains("accessibility labels"))
        XCTAssertTrue(report.localizationReadyStatement.contains("matching key sets"))
        XCTAssertTrue(report.releaseAuditStatement.contains("VoiceOver"))
        XCTAssertTrue(report.releaseAuditStatement.contains("Larger Text"))

        let voiceOver = report.findings.first { $0.area == .voiceOver }
        XCTAssertEqual(voiceOver?.status, .implemented)
        XCTAssertTrue(voiceOver?.detail.contains("History rows") == true)
        XCTAssertTrue(voiceOver?.coveredSurfaces.contains("Pinboards") == true)

        let nonColor = report.findings.first { $0.area == .nonColorStatus }
        XCTAssertEqual(nonColor?.status, .implemented)
        XCTAssertTrue(nonColor?.detail.contains("Differentiate Without Color") == true)

        let dynamicType = report.findings.first { $0.area == .dynamicType }
        XCTAssertTrue(dynamicType?.detail.contains("flexible") == true)
    }

    private func localizedStrings(locale: String) throws -> [String: String] {
        let url = try resourceURL(locale: locale)
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: String], "Unable to parse \(url.path) as a strings dictionary")
    }

    private func resourceURL(locale: String) throws -> URL {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("PasteBuddy", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("\(locale).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate PasteBuddy localization resources from \(FileManager.default.currentDirectoryPath)")
    }
}
