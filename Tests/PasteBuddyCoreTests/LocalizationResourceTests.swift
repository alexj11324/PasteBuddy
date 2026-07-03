import Foundation
@testable import PasteBuddyCore
import XCTest

final class LocalizationResourceTests: XCTestCase {
    func testEnglishAndSimplifiedChineseResourcesHaveMatchingKeys() throws {
        let english = try localizedStrings(locale: "en")
        let simplifiedChinese = try localizedStrings(locale: "zh-Hans")

        XCTAssertEqual(Set(english.keys), Set(simplifiedChinese.keys))
    }

    func testStringCatalogMatchesLegacyResourcesAndContainsReviewedChinese() throws {
        let english = try localizedStrings(locale: "en")
        let simplifiedChinese = try localizedStrings(locale: "zh-Hans")
        let catalog = try stringCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any], "String catalog must contain a strings object")

        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        XCTAssertEqual(catalog["version"] as? String, "1.0")
        XCTAssertEqual(Set(strings.keys), Set(english.keys))

        let allowedIdentityValues: Set<String> = [
            "Command",
            "Control",
            "HTML",
            "MCP",
            "Option",
            "PasteBuddy",
            "Shift",
            "URL"
        ]

        for (key, englishValue) in english {
            let catalogEntry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog entry for \(key)")
            let catalogEnglish = try catalogValue(catalogEntry, locale: "en", key: key)
            let catalogChinese = try catalogValue(catalogEntry, locale: "zh-Hans", key: key)
            let stringsChinese = try XCTUnwrap(simplifiedChinese[key], "Missing zh-Hans strings value for \(key)")

            XCTAssertEqual(catalogEnglish, englishValue, "\(key) catalog English must match Localizable.strings")
            XCTAssertEqual(catalogChinese, stringsChinese, "\(key) catalog zh-Hans must match Localizable.strings")
            XCTAssertFalse(catalogChinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) has empty zh-Hans catalog value")
            if catalogChinese == catalogEnglish {
                XCTAssertTrue(
                    allowedIdentityValues.contains(catalogEnglish),
                    "\(key) zh-Hans value is still identical to English: \(catalogEnglish)"
                )
            }
        }
    }

    func testPriorityUserFacingStringsHaveSimplifiedChineseTranslations() throws {
        let simplifiedChinese = try localizedStrings(locale: "zh-Hans")
        let priorityKeys = [
            "label.search_clipboard",
            "label.new_text_item",
            "label.labels",
            "action.save_labels",
            "label.clipboard_item_labels",
            "label.reusable_type",
            "label.code",
            "label.color",
            "label.template",
            "label.asset",
            "label.custom_capture_rules",
            "action.add_rule",
            "label.rule_pattern",
            "label.contains_text",
            "label.source_bundle_id",
            "action.paste_stack",
            "dialog.delete_pinboard",
            "message.items_stay_in_clipboard_history_only_this",
            "message.drop_clipboard_items_here_to_pin_them",
            "action.share_pinboard",
            "action.share_settings",
            "label.access_mode",
            "label.default_permission",
            "action.invite_participant",
            "label.participants",
            "action.stop_sharing",
            "label.read_only",
            "label.can_edit",
            "label.invitation_only",
            "label.link_access",
            "label.collecting",
            "label.paused",
            "label.next",
            "label.top_to_bottom",
            "label.bottom_to_top",
            "action.copy_as_plain_text",
            "action.paste_to_active_app",
            "action.paste_order",
            "message.multiple_selected_items_paste_as_plain_text",
            "action.clear_filters",
            "label.active_clipboard_filters",
            "message.run_local_apple_ocr_after_image_capture",
            "action.allow_local_agent_connection",
            "label.agent_connection",
            "label.agent_connection_status",
            "message.agent_connection_runs_on_this_mac",
            "message.agent_connection_step_1",
            "message.agent_connection_step_2",
            "message.agent_connection_step_3",
            "message.swift_run_pastebuddymcp_print_client_config_codex",
            "message.agent_connection_is_ready",
            "state.off",
            "action.sync_sharing",
            "action.request_accessibility_access",
            "label.last_direct_paste",
            "action.dismiss",
            "action.clear_shortcut",
            "label.key",
            "label.quick_paste_modifiers",
            "label.plain_text_quick_paste_modifiers",
            "action.save_to_pastebuddy",
            "action.copy_to_pastebuddy",
            "message.preparing_shared_content",
            "action.retry",
            "message.saving_shared_content_to_encrypted_history",
            "message.saving_shared_content_to_history",
            "mobile.share_action.import_result_history_one",
            "mobile.share_action.import_result_history",
            "mobile.share_action.import_result_history_and_pinboard_one",
            "mobile.share_action.import_result_history_and_pinboard",
            "label.mobile_setup",
            "action.restore_purchases",
            "label.storage_security",
            "label.estimated_history_size",
            "label.pinned_history_size",
            "label.unpinned_history_size",
            "label.storage_limit",
            "action.clear_all_history_including_pinned",
            "label.device_unlock",
            "label.trial",
            "label.supported_locales",
            "label.manual_release_audit",
            "label.voiceover",
            "label.larger_text",
            "label.appearance",
            "label.not_color_only",
            "label.localization",
            "label.implemented",
            "label.manual_audit_required",
            "label.require_touch_id_to_unlock",
            "action.unlock_history",
            "action.lock_history",
            "label.history_lock",
            "label.standard_local_storage",
            "label.confirm_action",
            "dialog.clear_unpinned_history",
            "dialog.clear_all_history",
            "message.this_removes_all_local_clipboard_history_including",
            "label.storage",
            "label.plans",
            "label.integrations",
            "label.more",
            "label.clipboard_shelf",
            "label.content_type_filter",
            "label.source_app_filter",
            "label.device_filter",
            "label.copied_date_filter",
            "message.removes_all_active_clipboard_filters",
            "format.move_to",
            "format.pin_to",
            "format.touch_id_grace_period_seconds",
            "format.keep_up_to_items",
            "format.use_up_to",
            "label.keep_history_forever",
            "format.keep_normal_history_for_days",
            "message.clipboard_details_ocr_text_and_pinning_actions",
            "message.separate_labels_with_commas",
            "format.remove_label",
            "message.saves_edits_back_to_clipboard_history",
            "action.start_collecting",
            "action.stop_collecting",
            "format.paste_stack",
            "format.pinboard",
            "format.color",
            "format.pinboard_color",
            "state.selected",
            "label.not_selected",
            "message.no_external_app_is_available_to_exclude",
            "format.excluded",
            "message.pastebuddy_could_not_create_this_item",
            "format.resumes_at",
            "label.pastebuddy_clipboard_shelf",
            "action.reload_clipboard_history",
            "action.add_item_or_pinboard",
            "label.more_actions",
            "message.new_copies_will_appear_here",
            "message.start_collecting_copied_items",
            "message.copy_text_links_screenshots_or_files_to",
            "action.stop_paste_stack",
            "action.start_paste_stack",
            "action.reverse_paste_stack",
            "action.show_clipboard_shelf",
            "label.shelf_position",
            "label.shelf_at_top",
            "label.shelf_at_bottom",
            "action.show_hide_clipboard_shelf",
            "action.open_pastebuddy",
            "action.open_settings",
            "format.settings",
            "action.disable_launch_at_login",
            "action.enable_launch_at_login",
            "label.launch_at_login_on",
            "label.launch_at_login_off",
            "label.pastebuddy_active",
            "label.pastebuddy_paused",
            "action.pause_capture_for_15_minutes",
            "action.pause_capture_for_1_hour",
            "action.pause_capture",
            "label.link",
            "label.clipboard_shelf_opened",
            "label.clipboard_shelf_closed",
            "action.open_clipboard_shelf",
            "action.copy_pastebuddy_item",
            "action.paste_pastebuddy_item",
            "action.copy_pastebuddy_item_as_plain",
            "action.paste_pastebuddy_item_as_plain",
            "action.undo_delete_pastebuddy_item",
            "action.pin_selected_to",
            "label.no_pinboards_available",
            "action.unpin_from_current_pinboard",
            "message.click_for_pastebuddy_menu",
            "label.pastebuddy_menu_bar_item",
            "action.hide_this_prompt",
            "action.open_at_login",
            "message.automatically_start_pastebuddy_when_your_mac_restarts",
            "message.launch_at_login_is_unavailable_in_this",
            "action.toggle_launch_at_login",
            "action.open_at_login.a7a8de0b",
            "format.showing_first_items",
            "format.refine_search_or_filters_to_see_more",
            "format.showing_first_clipboard_items_refine_search_or",
            "action.paste_next",
            "action.paste_order_preview",
            "label.settings_entry_point",
            "message.opened_from_the_menu_bar_the_related",
            "action.clear_settings_focus",
            "action.pause_15m",
            "action.pause_1h",
            "label.privacy_scope",
            "message.custom_rules_run_locally_before_capture_and",
            "message.touch_id_protects_access_to_the_history",
            "message.pinned_items_are_preserved_when_normal_history",
            "message.per_item_copy_and_paste_menus_still",
            "action.start_trial",
            "message.cleared_shortcuts_remain_available_from_menus_but",
            "state.required",
            "label.matched",
            "label.not_matched",
            "message.direct_paste_copies_the_selected_item_first",
            "label.new_text",
            "label.source_app",
            "label.full_screen_preview",
            "label.content",
            "label.category",
            "label.untitled",
            "label.extension_setup",
            "state.available",
            "state.optional",
            "action.paste_permission",
            "label.full_access",
            "label.limited",
            "label.drag",
            "action.insert",
            "action.copy_plain_text",
            "action.pin_to_pinboard",
            "message.double_click_or_press_return_to_paste",
            "format.file",
            "format.files",
            "format.chars",
            "label.not_needed",
            "label.ocr_pending",
            "label.ocr_complete",
            "label.ocr_failed",
            "label.capture_active.d7a4a72f",
            "label.capture_paused.04ddfd1a",
            "label.capture_paused_temporarily",
            "message.new_clipboard_content_is_evaluated_by_local",
            "message.automatic_clipboard_capture_is_stopped_until_you",
            "message.automatic_clipboard_capture_is_stopped_until_the"
        ]

        for key in priorityKeys {
            let translation = try XCTUnwrap(simplifiedChinese[key], "Missing translation for \(key)")
            XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(translation, key)
        }
    }

    func testiOSInfoPlistResourcesHaveSimplifiedChineseTranslations() throws {
        let targets = [
            "PasteBuddyiOS",
            "PasteBuddyKeyboard",
            "PasteBuddyShare",
            "PasteBuddyAction"
        ]

        for target in targets {
            let english = try stringsDictionary(at: infoPlistStringsURL(target: target, locale: "en"))
            let simplifiedChinese = try stringsDictionary(at: infoPlistStringsURL(target: target, locale: "zh-Hans"))

            XCTAssertEqual(Set(english.keys), Set(simplifiedChinese.keys), "\(target) InfoPlist keys differ")

            for (key, englishValue) in english {
                let translation = try XCTUnwrap(simplifiedChinese[key], "Missing \(target) InfoPlist translation for \(key)")
                XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if englishValue != "PasteBuddy" {
                    XCTAssertNotEqual(translation, englishValue, "\(target) InfoPlist \(key) is still English")
                }
            }
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
        return try stringsDictionary(at: url)
    }

    private func stringCatalog() throws -> [String: Any] {
        let url = try stringCatalogURL()
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Unable to parse \(url.path) as a string catalog"
        )
    }

    private func catalogValue(_ entry: [String: Any], locale: String, key: String) throws -> String {
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "\(key) missing localizations")
        let localePayload = try XCTUnwrap(localizations[locale] as? [String: Any], "\(key) missing \(locale)")
        let stringUnit = try XCTUnwrap(localePayload["stringUnit"] as? [String: Any], "\(key) missing \(locale) stringUnit")
        return try XCTUnwrap(stringUnit["value"] as? String, "\(key) missing \(locale) value")
    }

    private func stringsDictionary(at url: URL) throws -> [String: String] {
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

    private func stringCatalogURL() throws -> URL {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("PasteBuddy", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Localizable.xcstrings")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate PasteBuddy string catalog from \(FileManager.default.currentDirectoryPath)")
    }

    private func infoPlistStringsURL(target: String, locale: String) throws -> URL {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Support", isDirectory: true)
                .appendingPathComponent("InfoPlist", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent("\(locale).lproj", isDirectory: true)
                .appendingPathComponent("InfoPlist.strings")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate \(target) InfoPlist localization resources from \(FileManager.default.currentDirectoryPath)")
    }
}
