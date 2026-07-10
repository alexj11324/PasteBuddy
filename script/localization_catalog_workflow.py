#!/usr/bin/env python3
"""Materialize PasteBuddy's Dify-backed String Catalog target workflow.

The sync command converts Dify-reviewed Localizable.strings resources into the
String Catalog shape used by the iOS Xcode targets, creates stable semantic
keys, and rewrites already-localized Swift call sites to those keys.

The check command validates the catalog, the legacy SwiftPM .strings resources,
iOS target membership, placeholders, and static call sites that should no
longer use English sentence keys.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
RESOURCE_ROOT = ROOT / "Sources/PasteBuddy/Resources"
EN_STRINGS = RESOURCE_ROOT / "en.lproj/Localizable.strings"
ZH_HANS_STRINGS = RESOURCE_ROOT / "zh-Hans.lproj/Localizable.strings"
STRING_CATALOG = RESOURCE_ROOT / "Localizable.xcstrings"
XCODE_PROJECT = ROOT / "PasteBuddyiOS.xcodeproj/project.pbxproj"

LOCALES = ("en", "zh-Hans")
SEMANTIC_PREFIXES = {
    "action",
    "automation",
    "brand",
    "dialog",
    "format",
    "label",
    "message",
    "mobile",
    "mcp",
    "state",
    "value",
}

STRING_PAIR_RE = re.compile(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;')
STRING_LITERAL_RE = re.compile(r'"((?:\\.|[^"\\])*)"')
PLACEHOLDER_RE = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|@|[diuoxXfFeEgGcCsSpaA])")
WORD_RE = re.compile(r"[A-Za-z0-9]+")

USER_FACING_LINE_RE = re.compile(
    r"NSLocalizedString|String\(localized:|localized(?:Format)?\(|PasteBuddyLocalization\.(?:string|format)\(|"
    r"Text\(|Button\(|Label\(|LabeledContent\(|"
    r"Toggle\(|Picker\(|Section\(|Menu\(|TextField\(|ContentUnavailableView\(|"
    r"\.help\(|accessibility(?:Label|Hint|Value)\(|setAccessibilityLabel\(|"
    r"accessibilityDescription:|\.text\s*=|\.setTitle\("
)
DEFAULT_VALUE_CALL_RE = re.compile(
    r"(?:PasteBuddyLocalization\.(?:string|format)|localized(?:Format)?)"
    r"\(\s*\"((?:\\.|[^\"\\])*)\"\s*,\s*defaultValue:\s*\"((?:\\.|[^\"\\])*)\""
)
KEYED_LOCALIZATION_CALL_RE = re.compile(
    r"(?:NSLocalizedString|localized(?:Format)?|PasteBuddyLocalization\.(?:string|format))"
    r"\(\s*\"((?:\\.|[^\"\\])*)\""
)

SOURCE_ROOTS = [
    ROOT / "Sources/PasteBuddy",
    ROOT / "Sources/PasteBuddyCore",
    ROOT / "Sources/PasteBuddyMobile",
    ROOT / "Sources/PasteBuddyiOS",
    ROOT / "Sources/PasteBuddyKeyboard",
    ROOT / "Sources/PasteBuddyShareAction",
]

KNOWN_TERMS = {
    "api": "api",
    "app": "app",
    "asc": "asc",
    "cloudkit": "cloudkit",
    "command": "command",
    "html": "html",
    "icloud": "icloud",
    "ios": "ios",
    "ipad": "ipad",
    "iphone": "iphone",
    "json": "json",
    "mcp": "mcp",
    "ocr": "ocr",
    "pastebuddy": "pastebuddy",
    "pdf": "pdf",
    "swiftpm": "swiftpm",
    "storekit": "storekit",
    "touch": "touch",
    "url": "url",
    "voiceover": "voiceover",
}

ACTION_WORDS = {
    "add",
    "cancel",
    "clear",
    "copy",
    "create",
    "delete",
    "disable",
    "dismiss",
    "done",
    "enable",
    "hide",
    "insert",
    "invite",
    "lock",
    "open",
    "paste",
    "pause",
    "pin",
    "reload",
    "remove",
    "request",
    "restore",
    "resume",
    "retry",
    "reverse",
    "revoke",
    "save",
    "share",
    "show",
    "start",
    "stop",
    "sync",
    "toggle",
    "undo",
    "unlock",
    "unpin",
}


@dataclass(frozen=True)
class StringsEntry:
    key: str
    value: str
    line: int


@dataclass(frozen=True)
class CatalogEntry:
    canonical_key: str
    legacy_key: str
    english: str
    simplified_chinese: str


def semantic_entry(canonical_key: str, english: str, simplified_chinese: str) -> CatalogEntry:
    return CatalogEntry(
        canonical_key=canonical_key,
        legacy_key=canonical_key,
        english=english,
        simplified_chinese=simplified_chinese,
    )


EXTRA_CATALOG_ENTRIES = [
    CatalogEntry(
        canonical_key="action.hide_clipboard_shelf",
        legacy_key="Hide Clipboard Shelf",
        english="Hide Clipboard Shelf",
        simplified_chinese="隐藏剪贴板架",
    ),
    CatalogEntry(
        canonical_key="format.quick_paste_index",
        legacy_key="format.quick_paste_index",
        english="Quick Paste %d",
        simplified_chinese="快速粘贴 %d",
    ),
    CatalogEntry(
        canonical_key="format.quick_paste_index_as_plain_text",
        legacy_key="format.quick_paste_index_as_plain_text",
        english="Quick Paste %d as Plain Text",
        simplified_chinese="以纯文本快速粘贴 %d",
    ),
    semantic_entry("mobile.surface.iphone_app", "iPhone App", "iPhone 应用"),
    semantic_entry("mobile.surface.ipad_app", "iPad App", "iPad 应用"),
    semantic_entry("mobile.surface.keyboard_extension", "Keyboard Extension", "键盘扩展"),
    semantic_entry("mobile.surface.share_extension", "Share Extension", "分享扩展"),
    semantic_entry("mobile.surface.action_extension", "Action Extension", "操作扩展"),
    semantic_entry("mobile.ipad_mode.stage_manager", "Stage Manager", "台前调度"),
    semantic_entry("mobile.ipad_mode.split_view", "Split View", "分屏浏览"),
    semantic_entry("mobile.ipad_mode.slide_over", "Slide Over", "侧拉"),
    semantic_entry("mobile.ipad_mode.drag_and_drop", "Drag and Drop", "拖放"),
    semantic_entry("mobile.permission_state.unknown", "Unknown", "未知"),
    semantic_entry("mobile.permission_state.ask", "Ask", "询问"),
    semantic_entry("mobile.permission_state.allowed", "Allowed", "允许"),
    semantic_entry("mobile.permission_state.denied", "Denied", "拒绝"),
    semantic_entry("mobile.guidance_severity.ready", "Ready", "就绪"),
    semantic_entry("mobile.guidance_severity.optional", "Optional", "可选"),
    semantic_entry("mobile.guidance_severity.action_required", "Action Required", "需要操作"),
    semantic_entry("mobile.guidance_action.open_app_settings", "Open App Settings", "打开应用设置"),
    semantic_entry("mobile.guidance_action.open_keyboard_settings", "Open Keyboard Settings", "打开键盘设置"),
    semantic_entry("mobile.guidance_action.enable_share_extension", "Enable Share Extension", "启用分享扩展"),
    semantic_entry("mobile.guidance_action.enable_action_extension", "Enable Action Extension", "启用操作扩展"),
    semantic_entry("mobile.guidance_action.configure_app_group", "Configure App Group", "配置 App Group"),
    semantic_entry("mobile.guidance_action.continue_manual_import", "Continue Manual Import", "继续手动导入"),
    semantic_entry("mobile.automatic_capture.available", "Available", "可用"),
    semantic_entry("mobile.automatic_capture.needs_user_consent", "Needs User Consent", "需要用户同意"),
    semantic_entry("mobile.automatic_capture.denied", "Denied", "已拒绝"),
    semantic_entry("mobile.automatic_capture.explain_first", "Explain First", "先说明"),
    semantic_entry(
        "mobile.background_clipboard_limitation",
        "iOS and iPadOS do not permit dependable continuous background clipboard monitoring. PasteBuddy should browse synced or manually imported history, read the pasteboard only after foreground permission, and rely on Share or Action extensions for manual imports.",
        "iOS 和 iPadOS 不允许可靠的连续后台剪贴板监控。PasteBuddy 应浏览已同步或手动导入的历史，仅在前台获得权限后读取剪贴板，并依靠分享或操作扩展进行手动导入。",
    ),
    semantic_entry(
        "mobile.keyboard.full_access_privacy_explanation",
        "Full Access lets the keyboard read PasteBuddy's shared App Group history and insert selected text. Clipboard data stays on the user's device or private iCloud account unless the user explicitly enables sync or sharing.",
        "完全访问权限允许键盘读取 PasteBuddy 共享的 App Group 历史并插入所选文本。除非用户明确启用同步或分享，剪贴板数据会保留在用户设备或私人 iCloud 账户中。",
    ),
    semantic_entry(
        "mobile.share_action.unsupported_input_explanation",
        "PasteBuddy can save shared text, links, images, and supported file URLs. Unsupported provider payloads should fail with a clear message and no plaintext temporary files.",
        "PasteBuddy 可以保存分享的文本、链接、图片和受支持的文件 URL。不受支持的提供方载荷应给出清晰失败信息，且不留下明文临时文件。",
    ),
    semantic_entry(
        "mobile.share_action.favorite_reorder_guidance",
        "Users can add Save to PasteBuddy and Copy to PasteBuddy to iOS Share sheet favorites and reorder them from the system Share sheet edit screen.",
        "用户可以把“保存到 PasteBuddy”和“复制到 PasteBuddy”添加到 iOS 分享面板收藏，并在系统分享面板编辑界面重新排序。",
    ),
    semantic_entry(
        "automation.search.no_matches",
        'No PasteBuddy items matched "%@".',
        "没有匹配“%@”的 PasteBuddy 项目。",
    ),
    semantic_entry(
        "automation.search.match_one",
        '%d PasteBuddy item matched "%@": %@',
        "%d 个 PasteBuddy 项目匹配“%@”：%@",
    ),
    semantic_entry(
        "automation.search.match_many",
        '%d PasteBuddy items matched "%@": %@',
        "%d 个 PasteBuddy 项目匹配“%@”：%@",
    ),
    semantic_entry(
        "automation.create_item.created",
        'Created PasteBuddy item "%@".',
        "已创建 PasteBuddy 项目“%@”。",
    ),
    semantic_entry(
        "automation.create_item.saved_to_pinboard",
        'Created PasteBuddy item "%@" and saved it to %@.',
        "已创建 PasteBuddy 项目“%@”并保存到 %@。",
    ),
    semantic_entry(
        "automation.error.history_locked",
        "Unlock PasteBuddy history before running this action.",
        "运行此操作前，请先解锁 PasteBuddy 历史记录。",
    ),
    semantic_entry(
        "mcp.error.history_locked",
        "Unlock PasteBuddy history before using MCP clipboard tools.",
        "使用 MCP 剪贴板工具前，请先解锁 PasteBuddy 历史记录。",
    ),
    semantic_entry(
        "mobile.error.image_data_too_large",
        "The shared image is too large to import safely (limit: %d MB).",
        "分享的图片过大，无法安全导入（上限：%d MB）。",
    ),
    semantic_entry(
        "mobile.error.invalid_image_data",
        "The shared image data is invalid.",
        "分享的图片数据无效。",
    ),
    semantic_entry(
        "mobile.error.image_dimensions_too_large",
        "The shared image dimensions are too large to process safely.",
        "分享的图片尺寸过大，无法安全处理。",
    ),
    semantic_entry(
        "mobile.error.image_frame_count_too_large",
        "The shared image contains too many frames to process safely.",
        "分享的图片包含的帧数过多，无法安全处理。",
    ),
    semantic_entry(
        "mobile.error.history_load_failed",
        "PasteBuddy could not load encrypted history.",
        "PasteBuddy 无法加载加密历史记录。",
    ),
    semantic_entry(
        "mobile.error.history_unavailable_title",
        "History Unavailable",
        "历史记录不可用",
    ),
    semantic_entry(
        "message.history_unavailable",
        "PasteBuddy history is unavailable because it could not be loaded or saved safely.",
        "PasteBuddy 历史记录不可用，因为无法安全地加载或保存。",
    ),
    semantic_entry(
        "message.clipboard_capture_backlog_full",
        "Clipboard capture paused briefly because incoming content exceeded the safe memory budget.",
        "由于传入内容超出安全内存预算，剪贴板捕获已短暂暂停。",
    ),
    semantic_entry(
        "mobile.error.provider_load_timed_out",
        "The shared content took too long to load.",
        "分享内容加载时间过长。",
    ),
    semantic_entry(
        "mobile.error.shared_batch_too_large",
        "The shared content is too large to import safely (limit: %d MB).",
        "分享内容过大，无法安全导入（上限：%d MB）。",
    ),
    semantic_entry("automation.destination.clipboard", "Clipboard", "剪贴板"),
    semantic_entry("automation.destination.frontmost_app", "Frontmost App", "最前面的 App"),
    semantic_entry("action.add_app", "Add App", "添加应用"),
    semantic_entry("action.close", "Close", "关闭"),
    semantic_entry("action.manage_apps", "Manage Apps", "管理应用"),
    semantic_entry("label.installed_apps", "Installed Apps", "已安装应用"),
    semantic_entry("label.no_app_selected", "No App Selected", "未选择应用"),
    semantic_entry("label.no_excluded_apps", "No excluded apps", "没有已排除应用"),
    semantic_entry("label.search_apps", "Search Apps", "搜索应用"),
    semantic_entry("message.no_installed_apps_found", "No installed apps were found.", "未找到已安装应用。"),
    semantic_entry("message.no_matching_apps", "No matching apps.", "没有匹配的应用。"),
    semantic_entry(
        "automation.transfer.copied_to_clipboard",
        'Copied PasteBuddy item "%@" to the clipboard.',
        "已将 PasteBuddy 项目“%@”复制到剪贴板。",
    ),
    semantic_entry(
        "automation.transfer.prepared_for_frontmost_app",
        'Prepared PasteBuddy item "%@" for insertion into the frontmost app.',
        "已准备将 PasteBuddy 项目“%@”插入最前面的 App。",
    ),
    semantic_entry(
        "automation.error.empty_query",
        "Enter a search query before running this PasteBuddy action.",
        "运行此 PasteBuddy 操作前请输入搜索查询。",
    ),
    semantic_entry(
        "automation.error.empty_text",
        "Enter text before creating a PasteBuddy item.",
        "创建 PasteBuddy 项目前请输入文本。",
    ),
    semantic_entry(
        "automation.error.empty_content",
        "Enter content before creating a PasteBuddy item.",
        "创建 PasteBuddy 项目前请输入内容。",
    ),
    semantic_entry(
        "automation.error.empty_pinboard_name",
        "Enter a pinboard name before running this PasteBuddy action.",
        "运行此 PasteBuddy 操作前请输入收藏板名称。",
    ),
    semantic_entry(
        "automation.error.content_type_disabled",
        "%@ capture is disabled for PasteBuddy Shortcuts.",
        "PasteBuddy 快捷指令已停用 %@ 捕获。",
    ),
    semantic_entry(
        "automation.error.sensitive_text_blocked",
        "PasteBuddy blocked this action because the text looks sensitive.",
        "PasteBuddy 已阻止此操作，因为文本看起来包含敏感内容。",
    ),
    semantic_entry(
        "automation.error.capture_rule_blocked",
        'PasteBuddy blocked this action because it matched the local capture rule "%@".',
        "PasteBuddy 已阻止此操作，因为它匹配本地捕获规则“%@”。",
    ),
    semantic_entry(
        "automation.error.no_matching_item",
        "No matching PasteBuddy item was found.",
        "未找到匹配的 PasteBuddy 项目。",
    ),
    semantic_entry(
        "automation.error.pinboard_not_found",
        'No PasteBuddy pinboard named "%@" was found.',
        "未找到名为“%@”的 PasteBuddy 收藏板。",
    ),
    semantic_entry(
        "mobile.share_action.import_result_history_one",
        "Saved %d item to history.",
        "已将 %d 个项目保存到历史。",
    ),
    semantic_entry(
        "mobile.share_action.import_result_history",
        "Saved %d items to history.",
        "已将 %d 个项目保存到历史。",
    ),
    semantic_entry(
        "mobile.share_action.import_result_history_and_pinboard_one",
        "Saved %d item to history and selected pinboard.",
        "已将 %d 个项目保存到历史和所选收藏板。",
    ),
    semantic_entry(
        "mobile.share_action.import_result_history_and_pinboard",
        "Saved %d items to history and selected pinboard.",
        "已将 %d 个项目保存到历史和所选收藏板。",
    ),
    semantic_entry("mobile.share_action.saved_to_history", "Saved to history.", "已保存到历史。"),
    semantic_entry(
        "mobile.share_action.saved_to_history_and_pinboard",
        "Saved to history and selected pinboard.",
        "已保存到历史和所选收藏板。",
    ),
    semantic_entry("mobile.paste_permission.settings_path", "Settings > Apps > PasteBuddy > Allow Paste From Other Apps > Allow", "设置 > App > PasteBuddy > 允许从其他 App 粘贴 > 允许"),
    semantic_entry(
        "mobile.paste_permission.manual_workflows_remain_available",
        "Manual workflows remain available: browsing synced history, keyboard access, Share extension imports, and Action extension imports continue when automatic pasteboard capture is not allowed.",
        "手动流程仍然可用：即使不允许自动剪贴板捕获，也可以继续浏览已同步的历史、使用键盘访问，以及通过分享扩展和操作扩展导入。",
    ),
    semantic_entry(
        "mobile.paste_permission.dark_pattern_guardrail",
        "Do not block app launch, hide manual workflows, or imply clipboard data leaves the device/iCloud to pressure the user into enabling Allow.",
        "不要阻止应用启动、隐藏手动流程，或暗示剪贴板数据会离开设备/iCloud 来迫使用户启用“允许”。",
    ),
    semantic_entry("mobile.paste_permission.allowed.title", "Automatic capture is allowed", "已允许自动捕获"),
    semantic_entry(
        "mobile.paste_permission.allowed.detail",
        "PasteBuddy may read pasteboard content after foreground user activity and local privacy rules still apply before anything is saved.",
        "PasteBuddy 可在用户前台操作后读取剪贴板内容，并且保存任何内容前仍会应用本地隐私规则。",
    ),
    semantic_entry("mobile.paste_permission.ask.title", "Allow Paste From Other Apps is set to Ask", "“允许从其他 App 粘贴”设为询问"),
    semantic_entry(
        "mobile.paste_permission.ask.detail",
        "iOS will ask before PasteBuddy reads pasteboard content. Offer the Settings path only when the user wants automatic capture.",
        "iOS 会在 PasteBuddy 读取剪贴板内容前询问。仅在用户想启用自动捕获时提供设置路径。",
    ),
    semantic_entry("mobile.paste_permission.denied.title", "Paste access is denied", "粘贴访问已被拒绝"),
    semantic_entry(
        "mobile.paste_permission.denied.detail",
        "Automatic pasteboard capture is disabled. PasteBuddy should keep manual workflows available and offer Settings without blocking the app.",
        "自动剪贴板捕获已停用。PasteBuddy 应保留手动流程，并在不阻止使用应用的情况下提供设置入口。",
    ),
    semantic_entry("mobile.paste_permission.unknown.title", "Paste permission has not been checked", "尚未检查粘贴权限"),
    semantic_entry(
        "mobile.paste_permission.unknown.detail",
        "Explain why iOS asks before reading pasteboard content before attempting automatic capture.",
        "在尝试自动捕获前，先说明 iOS 为什么会在读取剪贴板内容前询问。",
    ),
    semantic_entry("mobile.summary.needs_one_action", "Mobile setup needs 1 action.", "移动端设置还需要 1 项操作。"),
    semantic_entry("mobile.summary.needs_actions", "Mobile setup needs %d actions.", "移动端设置还需要 %d 项操作。"),
    semantic_entry("mobile.summary.ready_optional_extensions", "Mobile browsing is ready; optional extensions can be enabled later.", "移动端浏览已就绪；可选扩展可稍后启用。"),
    semantic_entry("mobile.summary.ready_all", "Mobile browsing and extensions are ready.", "移动端浏览和扩展已就绪。"),
    semantic_entry("mobile.card.ipad_multitasking.title", "iPad browsing adapts to multitasking", "iPad 浏览适配多任务"),
    semantic_entry(
        "mobile.card.ipad_multitasking.detail",
        "The native mobile browser uses an adaptive split layout for portrait, landscape, Stage Manager, Split View, Slide Over, and drag-and-drop into pinboards.",
        "原生移动端浏览器会针对竖屏、横屏、台前调度、分屏浏览、侧拉，以及拖放到收藏板使用自适应分栏布局。",
    ),
    semantic_entry("mobile.card.background_capture_limit.title", "Background clipboard capture is limited", "后台剪贴板捕获受限"),
    semantic_entry("mobile.card.paste_access_allowed.title", "Paste access is allowed", "已允许粘贴访问"),
    semantic_entry("mobile.action.review_app_settings.title", "Review App Settings", "检查应用设置"),
    semantic_entry("mobile.action.review_app_settings.detail", "Use the iOS app target to open PasteBuddy settings when the user wants to change paste access.", "当用户想更改粘贴访问时，使用 iOS 应用目标打开 PasteBuddy 设置。"),
    semantic_entry("mobile.action.open_pastebuddy_settings.title", "Open PasteBuddy Settings", "打开 PasteBuddy 设置"),
    semantic_entry("mobile.action.use_manual_import.title", "Use Manual Import", "使用手动导入"),
    semantic_entry("mobile.action.use_manual_import.detail", "Share and Action extensions can still save selected content without automatic pasteboard reads.", "即使不自动读取剪贴板，分享和操作扩展仍可保存选中的内容。"),
    semantic_entry("mobile.paste_permission.denial_not_fatal", "PasteBuddy must not treat denial as fatal.", "PasteBuddy 不应把拒绝权限视为致命问题。"),
    semantic_entry("mobile.action.continue_without_automatic_capture.title", "Continue Without Automatic Capture", "不启用自动捕获并继续"),
    semantic_entry("mobile.action.continue_without_automatic_capture.detail", "Use Share or Action extension imports while paste access remains denied.", "粘贴访问仍被拒绝时，可使用分享或操作扩展导入。"),
    semantic_entry("mobile.action.prepare_settings_guidance.title", "Prepare Settings Guidance", "准备设置引导"),
    semantic_entry("mobile.action.prepare_settings_guidance.detail", "Show the settings path when the user opts into automatic capture.", "当用户选择启用自动捕获时显示设置路径。"),
    semantic_entry("mobile.card.keyboard_optional.title", "Keyboard extension is optional", "键盘扩展是可选项"),
    semantic_entry("mobile.card.keyboard_optional.detail", "Users can browse the main iOS app without enabling the custom keyboard. When enabled, PasteBuddy appears from the globe keyboard switcher.", "用户无需启用自定义键盘也可以浏览 iOS 主应用。启用后，PasteBuddy 会出现在地球键盘切换器中。"),
    semantic_entry("mobile.action.enable_keyboard_later.title", "Enable Keyboard Later", "稍后启用键盘"),
    semantic_entry("mobile.action.enable_keyboard_later.detail", "Add PasteBuddy from iOS Keyboard settings when in-app paste access is needed.", "需要应用内粘贴访问时，可从 iOS 键盘设置添加 PasteBuddy。"),
    semantic_entry("mobile.card.keyboard_full_access_enabled.title", "Keyboard Full Access is enabled", "键盘完全访问已启用"),
    semantic_entry("mobile.card.keyboard_full_access_needed.title", "Keyboard Full Access is needed", "需要键盘完全访问"),
    semantic_entry("mobile.card.keyboard_full_access_needed.detail", "Without Full Access, the keyboard should stay in limited mode and avoid claiming it can read synced history. %@", "没有完全访问权限时，键盘应保持受限模式，并避免声称可以读取已同步的历史。%@"),
    semantic_entry("mobile.action.open_keyboard_settings.detail", "Enable Full Access only after explaining that the keyboard reads PasteBuddy's shared history.", "只有在说明键盘会读取 PasteBuddy 的共享历史后，才启用完全访问。"),
    semantic_entry("mobile.card.share_extension_enabled.title", "Share extension is enabled", "分享扩展已启用"),
    semantic_entry("mobile.card.share_extension_available.title", "Share extension is available", "分享扩展可用"),
    semantic_entry("mobile.card.share_extension_enabled.detail", "Selected text, URLs, images, and files can be saved into history or a selected pinboard. %@", "选中的文本、URL、图片和文件可保存到历史或指定收藏板。%@"),
    semantic_entry("mobile.card.share_extension_available.detail", "Enable the Share extension when users want to save content from other apps without automatic pasteboard capture. %@", "当用户想在不自动捕获剪贴板的情况下保存其他 App 的内容时，可启用分享扩展。%@"),
    semantic_entry("mobile.action.enable_share_extension.detail", "Add PasteBuddy to the iOS Share sheet favorites.", "将 PasteBuddy 添加到 iOS 分享面板收藏。"),
    semantic_entry("mobile.card.action_extension_enabled.title", "Action extension is enabled", "操作扩展已启用"),
    semantic_entry("mobile.card.action_extension_available.title", "Action extension is available", "操作扩展可用"),
    semantic_entry("mobile.card.action_extension_enabled.detail", "The action extension can save supported selections directly into history or the preferred pinboard.", "操作扩展可将受支持的所选内容直接保存到历史或首选收藏板。"),
    semantic_entry("mobile.card.action_extension_available.detail", "Enable the action extension for one-tap Copy to PasteBuddy actions in compatible apps.", "启用操作扩展后，可在兼容 App 中一键使用“复制到 PasteBuddy”。"),
    semantic_entry("mobile.action.enable_action_extension.detail", "Expose PasteBuddy as a reusable iOS action.", "将 PasteBuddy 显示为可复用的 iOS 操作。"),
    semantic_entry("mobile.card.app_group.title", "App Group store", "App Group 存储"),
    semantic_entry("mobile.card.app_group.needs.detail", "Enabled mobile extensions must use the shared App Group store rather than plaintext handoff files.", "已启用的移动端扩展必须使用共享的 App Group 存储，而不是明文交接文件。"),
    semantic_entry("mobile.card.app_group.optional.detail", "App Group setup is only required when the signed app embeds keyboard, share, or action extensions.", "只有签名后的 App 内嵌键盘、分享或操作扩展时，才需要设置 App Group。"),
    semantic_entry("mobile.action.configure_app_group.detail", "Use the shared App Group store from the signed app and extension targets.", "在已签名 App 和扩展 target 中使用共享的 App Group 存储。"),
    semantic_entry("mobile.onboarding.allow_paste_from_other_apps.title", "Allow Paste From Other Apps", "允许从其他 App 粘贴"),
    semantic_entry("mobile.onboarding.allow_paste_from_other_apps.detail", "Use iOS Settings to move PasteBuddy from Ask to Allow when automatic capture is desired.", "需要自动捕获时，可在 iOS 设置中将 PasteBuddy 从“询问”改为“允许”。"),
    semantic_entry("mobile.onboarding.keyboard_full_access.title", "Keyboard Full Access", "键盘完全访问"),
    semantic_entry("mobile.onboarding.keyboard_full_access.detail", "Enable only when the user wants the keyboard extension to read synced history.", "仅在用户希望键盘扩展读取已同步的历史时启用。"),
    semantic_entry("mobile.onboarding.share_extension.title", "Share Extension", "分享扩展"),
    semantic_entry("mobile.onboarding.share_extension.detail", "Enable the extension to save text, links, images, and files from the iOS Share sheet.", "启用扩展后，可从 iOS 分享面板保存文本、链接、图片和文件。"),
    semantic_entry("mobile.keyboard_paste.outcome.inserted_text", "Inserted text", "已插入文本"),
    semantic_entry("mobile.keyboard_paste.outcome.full_access_required", "Full Access required", "需要完全访问权限"),
    semantic_entry("mobile.keyboard_paste.outcome.no_text_available", "No text available", "没有可用文本"),
    semantic_entry("mobile.keyboard_paste.outcome.insertion_failed", "Insertion failed", "插入失败"),
    semantic_entry("mobile.keyboard_paste.outcome.empty_selection", "No item selected", "未选择项目"),
    semantic_entry("mobile.keyboard_full_access_explanation.title", "Enable Full Access for PasteBuddy Keyboard", "为 PasteBuddy 键盘启用完全访问"),
    semantic_entry("mobile.keyboard_full_access_explanation.action_title", "Open Keyboard Settings", "打开键盘设置"),
    semantic_entry("mobile.keyboard_paste.status_inserted_characters", "Inserted %d character(s).", "已插入 %d 个字符。"),
    semantic_entry("mobile.keyboard_paste.status_full_access_required", "Keyboard Full Access is required.", "需要键盘完全访问权限。"),
    semantic_entry("mobile.keyboard_paste.status_no_text_available", "This item has no text representation the keyboard can insert.", "此项目没有键盘可插入的文本表示。"),
    semantic_entry("mobile.keyboard_paste.status_insertion_failed", "The host app did not accept inserted text.", "宿主 App 未接受插入的文本。"),
    semantic_entry("mobile.keyboard_paste.status_empty_selection", "Select a saved item before inserting from the keyboard.", "从键盘插入前，请先选择一个已保存项目。"),
]


def unescape_strings_value(value: str) -> str:
    try:
        return json.loads(f'"{value}"')
    except json.JSONDecodeError:
        return (
            value.replace(r"\\", "\\")
            .replace(r"\"", '"')
            .replace(r"\n", "\n")
            .replace(r"\r", "\r")
            .replace(r"\t", "\t")
        )


def escape_strings_value(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def parse_strings(path: Path) -> list[StringsEntry]:
    entries: list[StringsEntry] = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = STRING_PAIR_RE.search(line)
        if not match:
            continue
        entries.append(
            StringsEntry(
                key=unescape_strings_value(match.group(1)),
                value=unescape_strings_value(match.group(2)),
                line=lineno,
            )
        )
    return entries


def entries_dict(entries: Iterable[StringsEntry]) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in entries:
        result[entry.key] = entry.value
    return result


def duplicate_keys(entries: Iterable[StringsEntry]) -> list[str]:
    seen: set[str] = set()
    duplicates: set[str] = set()
    for entry in entries:
        if entry.key in seen:
            duplicates.add(entry.key)
        seen.add(entry.key)
    return sorted(duplicates)


def is_semantic_key(key: str) -> bool:
    if not re.fullmatch(r"[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+", key):
        return False
    return key.split(".", 1)[0] in SEMANTIC_PREFIXES


def words_for_key(text: str) -> list[str]:
    text = PLACEHOLDER_RE.sub(" ", text)
    words: list[str] = []
    for match in WORD_RE.finditer(text):
        raw = match.group(0)
        lower = raw.lower()
        words.append(KNOWN_TERMS.get(lower, lower))
    return words


def key_prefix(english: str, words: list[str]) -> str:
    stripped = english.strip()
    if stripped == "PasteBuddy":
        return "brand"
    if PLACEHOLDER_RE.search(english):
        return "format"
    if stripped.endswith("?"):
        return "dialog"
    if len(words) > 6 or "." in stripped:
        return "message"
    if words and words[0] in ACTION_WORDS:
        return "action"
    if stripped.lower() in {"on", "off", "enabled", "disabled", "selected", "available", "optional", "required"}:
        return "state"
    return "label"


def generated_key_for(english: str, used: set[str]) -> str:
    words = words_for_key(english)
    prefix = key_prefix(english, words)
    if not words:
        words = ["value"]
    limit = 7 if prefix in {"message", "format"} else 5
    slug = "_".join(words[:limit])
    slug = re.sub(r"_+", "_", slug).strip("_") or "value"
    base = f"{prefix}.{slug}"
    candidate = base
    if candidate not in used:
        used.add(candidate)
        return candidate
    digest = hashlib.sha1(english.encode("utf-8")).hexdigest()[:8]
    candidate = f"{base}.{digest}"
    counter = 2
    while candidate in used:
        candidate = f"{base}.{digest}{counter}"
        counter += 1
    used.add(candidate)
    return candidate


def build_catalog_entries() -> list[CatalogEntry]:
    english_entries = parse_strings(EN_STRINGS)
    chinese_values = entries_dict(parse_strings(ZH_HANS_STRINGS))
    english_values = entries_dict(english_entries)

    used = {entry.key for entry in english_entries if is_semantic_key(entry.key)}
    canonical_by_english: dict[str, str] = {}
    for entry in english_entries:
        if is_semantic_key(entry.key):
            canonical_by_english.setdefault(entry.value, entry.key)

    entries: list[CatalogEntry] = []
    for entry in english_entries:
        if is_semantic_key(entry.key):
            continue
        canonical = canonical_by_english.get(entry.value)
        if canonical is None:
            canonical = generated_key_for(entry.value, used)
            canonical_by_english[entry.value] = canonical
        entries.append(
            CatalogEntry(
                canonical_key=canonical,
                legacy_key=entry.key,
                english=entry.value,
                simplified_chinese=chinese_values.get(entry.key, english_values[entry.key]),
            )
        )

    # Preserve semantic entries that may have been added directly.
    legacy_keys = {entry.legacy_key for entry in entries}
    for entry in english_entries:
        if not is_semantic_key(entry.key) or entry.key in legacy_keys:
            continue
        entries.append(
            CatalogEntry(
                canonical_key=entry.key,
                legacy_key=entry.key,
                english=entry.value,
                simplified_chinese=chinese_values.get(entry.key, entry.value),
            )
        )
    for extra in EXTRA_CATALOG_ENTRIES:
        for index, entry in enumerate(entries):
            if entry.canonical_key == extra.canonical_key and entry.legacy_key == extra.legacy_key:
                entries[index] = extra
                break
        else:
            entries.append(extra)
    return sorted(entries, key=lambda item: item.canonical_key)


def write_strings(path: Path, locale: str, entries: list[CatalogEntry]) -> None:
    lines: list[str] = []
    lines.append("/* Canonical semantic keys. Prefer these keys in SwiftUI and code. */")
    seen_canonical: set[str] = set()
    for entry in entries:
        if entry.canonical_key in seen_canonical:
            continue
        seen_canonical.add(entry.canonical_key)
        value = entry.english if locale == "en" else entry.simplified_chinese
        lines.append(f'"{escape_strings_value(entry.canonical_key)}" = "{escape_strings_value(value)}";')
    lines.append("")
    lines.append("/* Legacy compatibility aliases for model displayName values and older persisted flows. */")
    seen_aliases: set[str] = set()
    for entry in entries:
        if entry.legacy_key == entry.canonical_key:
            continue
        if entry.legacy_key in seen_aliases:
            continue
        seen_aliases.add(entry.legacy_key)
        value = entry.english if locale == "en" else entry.simplified_chinese
        lines.append(f'"{escape_strings_value(entry.legacy_key)}" = "{escape_strings_value(value)}";')
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def catalog_string_entry(entry: CatalogEntry, key: str, is_legacy_alias: bool) -> dict[str, object]:
    result: dict[str, object] = {
        "localizations": {
            "en": {
                "stringUnit": {
                    "state": "translated",
                    "value": entry.english,
                }
            },
            "zh-Hans": {
                "stringUnit": {
                    "state": "translated",
                    "value": entry.simplified_chinese,
                }
            },
        }
    }
    if is_legacy_alias:
        result["comment"] = f"Legacy alias for {entry.canonical_key}. Prefer the semantic key in code."
    return result


def write_catalog(entries: list[CatalogEntry]) -> None:
    strings: dict[str, object] = {}
    for entry in entries:
        strings.setdefault(entry.canonical_key, catalog_string_entry(entry, entry.canonical_key, False))
    for entry in entries:
        if entry.legacy_key == entry.canonical_key:
            continue
        strings[entry.legacy_key] = catalog_string_entry(entry, entry.legacy_key, True)
    payload = {
        "sourceLanguage": "en",
        "strings": dict(sorted(strings.items())),
        "version": "1.0",
    }
    STRING_CATALOG.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def replacement_map(entries: list[CatalogEntry]) -> dict[str, str]:
    return {
        entry.legacy_key: entry.canonical_key
        for entry in entries
        if entry.legacy_key != entry.canonical_key
    }


def should_rewrite_line(path: Path, line: str) -> bool:
    return bool(USER_FACING_LINE_RE.search(line))


def should_skip_literal(line: str, start: int) -> bool:
    prefix = line[max(0, start - 36) : start]
    literal_prefix = line[max(0, start - 3) : start]
    if literal_prefix == r"\(":
        return True
    if "defaultValue:" in prefix:
        return True
    if re.search(r"(systemImage|systemName|systemSymbolName)\s*:", line[:start]):
        return True
    if re.search(r"(systemImage|systemSymbolName|image|forType|keyEquivalent|name|id)\s*:\s*$", prefix):
        return True
    if "sourceAppName:" in prefix or "sourceBundleIdentifier:" in prefix:
        return True
    return False


def should_skip_raw_literal(literal: str, line: str, start: int) -> bool:
    if should_skip_literal(line, start):
        return True
    if not literal.strip():
        return True
    if r"\(" in literal:
        return True
    if not re.search(r"[A-Za-z]", literal):
        return True
    if literal.startswith("com."):
        return True
    if re.fullmatch(r"[A-Za-z0-9_.-]{1,3}", literal):
        return True
    if re.fullmatch(r"[a-z0-9]+(?:\.[a-z0-9]+)+", literal) and not is_semantic_key(literal):
        return True
    return False


def rewrite_line_literals(line: str, replacements: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        literal = unescape_strings_value(match.group(1))
        if literal not in replacements or should_skip_literal(line, match.start()):
            return match.group(0)
        return f'"{escape_strings_value(replacements[literal])}"'

    return STRING_LITERAL_RE.sub(replace, line)


def rewrite_swift_sources(entries: list[CatalogEntry]) -> int:
    replacements = replacement_map(entries)
    changed = 0
    paths: list[Path] = []
    for root in SOURCE_ROOTS:
        if root.exists():
            paths.extend(sorted(root.rglob("*.swift")))
    for path in paths:
        original = path.read_text(encoding="utf-8")
        new_lines: list[str] = []
        did_change = False
        for line in original.splitlines():
            if should_rewrite_line(path, line):
                rewritten = rewrite_line_literals(line, replacements)
                if rewritten != line:
                    did_change = True
                new_lines.append(rewritten)
            else:
                new_lines.append(line)
        if did_change:
            path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
            changed += 1
    return changed


def validate_catalog_shape(problems: list[str]) -> dict[str, object] | None:
    if not STRING_CATALOG.exists():
        problems.append(f"Missing {STRING_CATALOG.relative_to(ROOT)}")
        return None
    try:
        payload = json.loads(STRING_CATALOG.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        problems.append(f"{STRING_CATALOG.relative_to(ROOT)} is invalid JSON: {error}")
        return None
    if payload.get("sourceLanguage") != "en":
        problems.append("Localizable.xcstrings sourceLanguage must be en")
    if payload.get("version") != "1.0":
        problems.append("Localizable.xcstrings version must be 1.0")
    if not isinstance(payload.get("strings"), dict):
        problems.append("Localizable.xcstrings strings must be an object")
    return payload


def localized_value(catalog_entry: object, locale: str) -> str | None:
    if not isinstance(catalog_entry, dict):
        return None
    localizations = catalog_entry.get("localizations")
    if not isinstance(localizations, dict):
        return None
    locale_payload = localizations.get(locale)
    if not isinstance(locale_payload, dict):
        return None
    string_unit = locale_payload.get("stringUnit")
    if not isinstance(string_unit, dict):
        return None
    value = string_unit.get("value")
    return value if isinstance(value, str) else None


def validate_resources(entries: list[CatalogEntry], problems: list[str]) -> None:
    english_entries = parse_strings(EN_STRINGS)
    chinese_entries = parse_strings(ZH_HANS_STRINGS)
    english_duplicates = duplicate_keys(english_entries)
    chinese_duplicates = duplicate_keys(chinese_entries)
    if english_duplicates:
        problems.append(f"Duplicate English Localizable.strings keys: {', '.join(english_duplicates[:8])}")
    if chinese_duplicates:
        problems.append(f"Duplicate zh-Hans Localizable.strings keys: {', '.join(chinese_duplicates[:8])}")

    english = entries_dict(english_entries)
    chinese = entries_dict(chinese_entries)
    if set(english) != set(chinese):
        problems.append("English and zh-Hans Localizable.strings key sets differ")

    for key, english_value in english.items():
        chinese_value = chinese.get(key)
        if chinese_value is None:
            continue
        if not chinese_value.strip():
            problems.append(f"{key}: empty zh-Hans translation")
        if PLACEHOLDER_RE.findall(english_value) != PLACEHOLDER_RE.findall(chinese_value):
            problems.append(f"{key}: placeholder mismatch between en and zh-Hans strings")

    expected_canonical = {entry.canonical_key for entry in entries}
    if not expected_canonical:
        problems.append("No semantic localization keys were found")
    missing_semantic = [key for key in expected_canonical if key not in english]
    if missing_semantic:
        problems.append(f"Missing semantic keys in Localizable.strings: {', '.join(missing_semantic[:8])}")


def validate_catalog_values(entries: list[CatalogEntry], payload: dict[str, object] | None, problems: list[str]) -> None:
    if payload is None:
        return
    strings = payload.get("strings")
    if not isinstance(strings, dict):
        return
    expected_keys = {entry.canonical_key for entry in entries} | {
        entry.legacy_key for entry in entries if entry.legacy_key != entry.canonical_key
    }
    missing = sorted(expected_keys - set(strings))
    if missing:
        problems.append(f"Localizable.xcstrings is missing keys: {', '.join(missing[:8])}")
    for key in sorted(expected_keys & set(strings)):
        english_value = localized_value(strings[key], "en")
        chinese_value = localized_value(strings[key], "zh-Hans")
        if english_value is None:
            problems.append(f"{key}: missing en stringUnit")
            continue
        if chinese_value is None:
            problems.append(f"{key}: missing zh-Hans stringUnit")
            continue
        if not chinese_value.strip():
            problems.append(f"{key}: empty zh-Hans catalog value")
        if PLACEHOLDER_RE.findall(english_value) != PLACEHOLDER_RE.findall(chinese_value):
            problems.append(f"{key}: placeholder mismatch in catalog")
        if not is_semantic_key(key):
            catalog_entry = strings[key]
            if not isinstance(catalog_entry, dict) or "Legacy alias for" not in str(catalog_entry.get("comment", "")):
                problems.append(f"{key}: non-semantic catalog key must be marked as a legacy alias")


def validate_project_membership(problems: list[str]) -> None:
    if not XCODE_PROJECT.exists():
        problems.append("Missing PasteBuddyiOS.xcodeproj/project.pbxproj")
        return
    project = XCODE_PROJECT.read_text(encoding="utf-8")
    catalog_resource_count = project.count("Localizable.xcstrings in Resources")
    legacy_resource_count = project.count("Localizable.strings in Resources")
    if catalog_resource_count < 4:
        problems.append("Localizable.xcstrings must be included in all four iOS target resource phases")
    if legacy_resource_count:
        problems.append("iOS target resources must use Localizable.xcstrings instead of Localizable.strings")
    if "text.json.xcstrings" not in project or "Sources/PasteBuddy/Resources/Localizable.xcstrings" not in project:
        problems.append("Xcode project is missing the Localizable.xcstrings file reference")


def validate_catalog_compiles(problems: list[str]) -> None:
    tmp_root = ROOT / "tmp"
    tmp_root.mkdir(exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="localization-xcstringstool-", dir=tmp_root) as output_dir:
            result = subprocess.run(
                [
                    "xcrun",
                    "xcstringstool",
                    "compile",
                    str(STRING_CATALOG),
                    "--output-directory",
                    output_dir,
                    "--language",
                    "en",
                    "--language",
                    "zh-Hans",
                    "--serialization-format",
                    "text",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
    except FileNotFoundError:
        problems.append("xcrun is not available; cannot compile Localizable.xcstrings")
        return
    except subprocess.TimeoutExpired:
        problems.append("xcstringstool timed out while compiling Localizable.xcstrings")
        return
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        problems.append(f"xcstringstool failed to compile Localizable.xcstrings: {detail or result.returncode}")


def validate_swift_call_sites(entries: list[CatalogEntry], problems: list[str]) -> None:
    replacements = replacement_map(entries)
    known_keys = {entry.canonical_key for entry in entries} | {entry.legacy_key for entry in entries}
    english_by_key = {entry.canonical_key: entry.english for entry in entries}
    english_by_key.update({entry.legacy_key: entry.english for entry in entries})
    for root in SOURCE_ROOTS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.swift")):
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                if not should_rewrite_line(path, line):
                    continue
                rel = path.relative_to(ROOT)
                for match in DEFAULT_VALUE_CALL_RE.finditer(line):
                    key = unescape_strings_value(match.group(1))
                    default_value = unescape_strings_value(match.group(2))
                    if key not in known_keys:
                        problems.append(f"{rel}:{lineno}: localization key {key!r} is missing from Localizable resources")
                        continue
                    expected = english_by_key.get(key)
                    if expected is not None and expected != default_value:
                        problems.append(
                            f"{rel}:{lineno}: defaultValue for {key!r} must match English catalog value {expected!r}"
                        )
                for match in KEYED_LOCALIZATION_CALL_RE.finditer(line):
                    key = unescape_strings_value(match.group(1))
                    if is_semantic_key(key) and key not in known_keys:
                        problems.append(f"{rel}:{lineno}: localization key {key!r} is missing from Localizable resources")
                if r"\(" in line:
                    continue
                for match in STRING_LITERAL_RE.finditer(line):
                    literal = unescape_strings_value(match.group(1))
                    if literal in replacements and not should_skip_literal(line, match.start()):
                        problems.append(
                            f"{rel}:{lineno}: use semantic key {replacements[literal]!r} instead of {literal!r}"
                        )
                        continue
                    if should_skip_raw_literal(literal, line, match.start()):
                        continue
                    if is_semantic_key(literal):
                        if literal not in known_keys:
                            problems.append(f"{rel}:{lineno}: localization key {literal!r} is missing from Localizable resources")
                        continue
                    problems.append(f"{rel}:{lineno}: user-facing literal {literal!r} must use a semantic localization key")


def run_sync(rewrite_swift: bool) -> int:
    entries = build_catalog_entries()
    write_strings(EN_STRINGS, "en", entries)
    write_strings(ZH_HANS_STRINGS, "zh-Hans", entries)
    write_catalog(entries)
    changed_sources = rewrite_swift_sources(entries) if rewrite_swift else 0
    print(
        json.dumps(
            {
                "semantic_keys": len({entry.canonical_key for entry in entries}),
                "legacy_aliases": len([entry for entry in entries if entry.legacy_key != entry.canonical_key]),
                "rewritten_swift_files": changed_sources,
                "catalog": str(STRING_CATALOG.relative_to(ROOT)),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def run_check() -> int:
    entries = build_catalog_entries()
    problems: list[str] = []
    validate_resources(entries, problems)
    payload = validate_catalog_shape(problems)
    validate_catalog_values(entries, payload, problems)
    validate_project_membership(problems)
    validate_catalog_compiles(problems)
    validate_swift_call_sites(entries, problems)
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "status": "ok",
                "semantic_keys": len({entry.canonical_key for entry in entries}),
                "catalog_keys": len(json.loads(STRING_CATALOG.read_text(encoding="utf-8"))["strings"]),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    sync_parser = subparsers.add_parser("sync", help="Regenerate Localizable.xcstrings and .strings resources.")
    sync_parser.add_argument("--rewrite-swift", action="store_true", help="Rewrite localized Swift literals to semantic keys.")
    subparsers.add_parser("check", help="Validate the String Catalog workflow.")
    args = parser.parse_args()

    if args.command == "sync":
        return run_sync(args.rewrite_swift)
    if args.command == "check":
        return run_check()
    parser.error(f"Unsupported command {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
