# iOS And iPadOS Integrations

PasteBuddy now has a SwiftPM macOS app plus `PasteBuddyiOS.xcodeproj`, which
builds a native iPhone/iPad host app and embeds the PasteBuddy keyboard
extension, Share extension, and Action extension.

## Implemented In Shared Core

- `PasteBuddyCore` declares iOS 17.5+ support and is verified against the iPhone
  Simulator SDK as a SwiftPM target.
- `PasteBuddyMobile` provides reusable SwiftUI screens for native iPhone/iPad
  browsing, manual text item creation, keyboard-extension history access, and
  share/action import flows.
- `MobileClipboardBrowserView` implements the native mobile browser shell:
  adaptive `NavigationSplitView` history/pinboard browsing, keyword search,
  content type/source app/device/date filters, active filter chips, full-screen
  preview, original and plain-text copy actions, row context menus, and iPad
  drag-and-drop into pinboards.
- `MobilePasteboardWriter` writes text, URLs, images, and plain-text fallbacks
  through `UIPasteboard` when compiled on iOS, while remaining an unavailable
  stub on non-UIKit platforms.
- `MobileKeyboardHistoryView` provides the reusable keyboard-extension history
  surface with History/Paste Stack/Pinboard scope switching, search, long-press
  actions, plain-text drag payloads, and Full Access status/guidance.
- `MobileKeyboardPasteService` is the testable insertion boundary used by
  `KeyboardViewController` to call `textDocumentProxy.insertText(_:)`; it blocks
  encrypted-history insertion when the keyboard extension is enabled but Full
  Access is missing.
- `MobileItemProviderAdapter` converts `NSItemProvider` values from Share and
  Action extensions into `SharedContentInput` for text, URLs, file URLs, and
  image data.
- `MobileShareActionExtensionService` batches supported Share/Action
  `NSItemProvider` payloads into encrypted history and an optional selected
  pinboard, while unsupported payloads fail with a clean localized message.
- `MobileIntegrationConfiguration` stores iOS paste permission state, keyboard
  extension enablement, keyboard Full Access state, share/action extension
  enablement, and a preferred share pinboard.
- `MobileOnboardingStep` produces checklist state for paste permission,
  keyboard Full Access, and Share extension setup.
- `MobileBrowsingCapabilities`, `MobileKeyboardExtensionCapabilities`,
  `MobileShareActionExtensionCapabilities`, and
  `MobileIntegrationGuidanceReport` convert paste permission, keyboard Full
  Access, share/action extension, iPad multitasking support, background
  clipboard limitations, iOS Share sheet favorite/reorder guidance, and
  encrypted App Group state into reusable user-facing guidance cards.
  Ask/Denied paste access remains non-fatal: automatic capture is withheld,
  while browsing and manual share/action imports can continue.
- `MobileOnboardingGuidanceView` renders the guidance report for the iOS/iPadOS
  app target, and keyboard/share views surface the relevant setup warnings
  without embedding secrets or target-specific identifiers.
- `SharedContentImportService` turns extension-provided text, URLs, file
  references, and image data into encrypted PasteBuddy history items.
- Shared imports respect content-type capture toggles and local sensitive-text
  blocking before writing to the encrypted store.
- Shared image imports are marked OCR pending when local OCR is enabled so the
  iOS/iPadOS target can run Apple Vision recognition immediately after the item
  is saved.
- `MobileStoreFactory` uses
  `EncryptedSnapshotStore.appGroupStore(groupIdentifier:)` for app/extension
  sharing and falls back to the app sandbox store when the placeholder App Group
  is unavailable in local simulator builds.

## Implemented Xcode Targets

- `PasteBuddyiOS.xcodeproj` contains the `PasteBuddyiOS` app scheme and the
  embedded `PasteBuddyKeyboard`, `PasteBuddyShareExtension`, and
  `PasteBuddyActionExtension` app extension targets.
- `PasteBuddyiOSApp` loads the mobile store and embeds
  `MobileClipboardBrowserView`.
- `KeyboardViewController` embeds `MobileKeyboardHistoryView`, wires
  `MobileKeyboardPasteService` to `textDocumentProxy.insertText(_:)`, and
  refreshes keyboard Full Access state from `UIInputViewController.hasFullAccess`.
- `ShareActionViewController` is shared by the Share and Action extension
  targets. It reads the extension `NSItemProvider` attachments, imports
  supported text, web URLs, file URLs, and images through
  `MobileShareActionExtensionService`, and marks Share/Action enablement in the
  encrypted mobile configuration.
- The iOS app and extension targets use the App Group entitlement
  `group.com.alexjiang.PasteBuddy` under Apple Developer Team `72UN4PF4BL`.
- The keyboard extension requests Open Access so the system exposes the Full
  Access switch required for encrypted shared-history browsing.

## External Signing Still Required

- Signed App Store / TestFlight provisioning profiles so device builds can
  access the encrypted shared store without plaintext handoff.

The checked-in simulator project uses real bundle identifiers and entitlements,
while simulator builds still work without a physical-device provisioning
profile.

## Support Templates

Example signing inputs live under `Support/`:

- `Support/Entitlements/PasteBuddy-iOS.entitlements.example`
- `Support/Entitlements/PasteBuddyKeyboard.entitlements.example`
- `Support/Entitlements/PasteBuddyShareAction.entitlements.example`
- `Support/InfoPlist/PasteBuddyKeyboard-Info.plist.example`
- `Support/InfoPlist/PasteBuddyShare-Info.plist.example`
- `Support/InfoPlist/PasteBuddyAction-Info.plist.example`

These mirror the real local identifiers: `group.com.alexjiang.PasteBuddy` and
`iCloud.com.alexjiang.PasteBuddy`.

The checked-in local simulator targets use:

- `Support/Entitlements/PasteBuddy-iOS.entitlements`
- `Support/Entitlements/PasteBuddyKeyboard.entitlements`
- `Support/Entitlements/PasteBuddyShareAction.entitlements`
- `Support/InfoPlist/PasteBuddyiOS-Info.plist`
- `Support/InfoPlist/PasteBuddyKeyboard-Info.plist`
- `Support/InfoPlist/PasteBuddyShare-Info.plist`
- `Support/InfoPlist/PasteBuddyAction-Info.plist`

## Shared Core Verification

Use these commands to verify that the shared core and reusable mobile UI still
compile for iOS Simulator without pulling in macOS-only AppKit pasteboard APIs:

```bash
swift build --target PasteBuddyCore \
  --triple arm64-apple-ios17.5-simulator \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk

swift build --target PasteBuddyMobile \
  --triple arm64-apple-ios17.5-simulator \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk
```

Use this command to build the runnable simulator app and embedded keyboard,
Share, and Action extensions. Keeping DerivedData under `/private/tmp` avoids
Desktop/FileProvider extended attributes that can make simulator code signing
reject app bundles.

```bash
xcodebuild -project PasteBuddyiOS.xcodeproj \
  -scheme PasteBuddyiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath /private/tmp/pastebuddy-ios-deriveddata \
  build
```

The macOS app target remains macOS-only. `ClipboardMonitor`, `PasteboardWriter`,
and `NSImage` helpers compile only on macOS, while `OCRService` uses AppKit on
macOS and UIKit image decoding on iOS.

## Permission Guidance

iOS controls pasteboard access with system prompts and the Allow Paste from
Other Apps setting. iOS and iPadOS do not permit dependable continuous
background clipboard monitoring. PasteBuddy should never treat denial as fatal.
The expected flow is:

1. Store `.ask`, `.allowed`, or `.denied` in `MobileIntegrationConfiguration`.
2. Build the setup screen from `MobileIntegrationGuidanceReport` instead of
   hard-coding a second copy of the permission rules in the app target.
3. Use `MobilePastePermissionGuidance` for the Settings path, automatic capture
   status, manual workflow fallback text, and no-dark-pattern guardrail.
4. Show onboarding only when automatic capture or keyboard access needs it.
5. Read the pasteboard only after foreground permission or explicit user action.
6. Continue allowing browsing, keyboard access, Share extension imports, and
   Action extension imports when paste access is Ask or Denied.
7. Keep all imported content local and encrypted unless sync is explicitly
   configured.

`MobilePastePermissionGuidance.settingsPath` intentionally uses the explicit
path "Settings > Apps > PasteBuddy > Allow Paste From Other Apps > Allow".
The app should offer that path only when the user wants automatic capture; it
must not block app launch, hide manual workflows, or imply clipboard data leaves
the device/iCloud to pressure the user into changing the setting.

## Keyboard Extension Flow

The reusable keyboard view can browse encrypted history, Paste Stack, and
pinboards from the same shared store as the app. Tapping an item should call
`MobileKeyboardPasteService.paste(_:format:configuration:)`, which inserts the
plain-text representation through the extension's `textDocumentProxy`. Long
press exposes insert, copy, plain-text copy, and pin-to-pinboard actions, while
dragging an item exports plain text for iPad drag-and-drop.

Full Access is required before the keyboard claims it can read the encrypted
shared App Group history. The guidance copy must state that Full Access lets the
keyboard read PasteBuddy's encrypted shared history and insert selected text;
clipboard data stays on the user's device or private iCloud account unless the
user explicitly enables sync or sharing.

Simulator verification path:

1. Build and launch `PasteBuddyiOS`.
2. Use `New Text` in the iOS app to save a text item.
3. Open Settings > General > Keyboard > Keyboards > Add New Keyboard.
4. Select PasteBuddy, then open PasteBuddy Keyboard and enable Full Access.
5. Switch to PasteBuddy from the globe keyboard switcher in any text field and
   tap a saved item to insert its plain-text representation.

## Share And Action Extension Flow

The Share extension is surfaced as "Save to PasteBuddy" and the Action
extension as "Copy to PasteBuddy". Users can add both to iOS Share sheet
favorites and reorder them from the system Share sheet edit screen; PasteBuddy
only provides the extension metadata and in-extension guidance.

The signed Share and Action targets pass their `NSItemProvider` values to
`MobileShareActionExtensionService.importSupportedContent(from:into:configuration:)`.
The service supports text, web URLs, file URLs, and image data, saves each item
to encrypted history, and pins the imported items when the user selects a
pinboard. Unsupported provider payloads should surface the localized
`MobileItemProviderAdapterError.unsupportedContent` message instead of writing
plaintext staging files or swallowing the failure.

Simulator verification should confirm that
`PasteBuddyiOS.app/PlugIns/PasteBuddyShareExtension.appex` exposes
`com.apple.share-services` and
`PasteBuddyiOS.app/PlugIns/PasteBuddyActionExtension.appex` exposes
`com.apple.ui-services`.

## Privacy Rules

Extensions should not write temporary plaintext files. If an extension must
stage a large payload, it should use an App Group container with the same
encrypted envelope policy as the main app and remove intermediate files after
import.

Share and Action imports must use the shared `PrivacyConfiguration` capture
decision path before saving to encrypted history or pinboards. That keeps
content-type toggles, local sensitive-text blocking, custom capture rules, and
source bundle identifier rules consistent with Mac capture, Shortcuts, search,
keyboard history browsing, and MCP access.
