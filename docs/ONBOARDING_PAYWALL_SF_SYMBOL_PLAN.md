# Onboarding and Paywall SF Symbol Plan

## Current-state audit

- PasteBuddy uses a contextual native AI Search setup/paywall sheet from Settings,
  Shelf, and Side Panel. It is built with SwiftUI `Form`-style controls, StoreKit,
  and SF Symbols; it is not a separate onboarding window.
- Accessibility permission is exposed in Settings for direct paste. OCR has a
  Settings toggle; OCR and translation do not yet have first-run/how-to pages.
  Screenshot capture and Screen Recording permission are out of scope.
- Plans use `AppleStoreKitEntitlementProvider`, verified transactions, product
  fetch/purchase/restore, and transaction updates. There is no locally simulated
  trial, lifetime product, or local account system.
- Existing Settings and status-menu affordances already use SF Symbols. Installed
  application icons shown by application pickers are the external apps' real icons,
  not onboarding/paywall artwork, and are outside this constraint.

Any additional onboarding or paywall UI must continue to use these existing state,
permission, and StoreKit owners.

## Proposed native flow and symbol mapping

| Step/status/action | SF Symbol | Text/accessibility requirement |
|---|---|---|
| Welcome / clipboard history | `doc.on.clipboard` | “Welcome to PasteBuddy”; explain local history in text |
| Local privacy | `hand.raised.fill` | “Clipboard data stays under your selected local/sync policy” |
| Direct-paste Accessibility | `accessibility` | “Allow Accessibility for direct paste”; show current trusted/not-trusted text |
| OCR how-to | `text.viewfinder` | “Recognize selectable text and QR/barcodes locally with Vision” |
| Translation how-to | `character.bubble` | “Translate text with macOS Translation”; show unavailable/download/error text |
| Ready/success | `checkmark.circle.fill` | Explicit ready message; never success by color/icon alone |
| Warning/failure | `exclamationmark.triangle.fill` | Localized error plus recovery action |
| Unlock paid features | `lock.open.fill` | Paywall title and entitlement state in text |
| AI semantic search | `sparkles` | “AI Search”; processing and applied-result state also use localized text |
| Local/BYOK privacy | `hand.raised.fill` | Explain local index, direct provider routing, and Keychain boundary |
| BYOK plan/provider | `key.fill` | “BYOK Annual” or “Configure your API”; never expose the key in labels or logs |
| Provider routing | `arrow.triangle.branch` | “PasteBuddy Cloud” or “Bring Your Own Key” in text |
| Subscription sidebar | `shield` | “Subscription” text label; sidebar state is never icon-only |
| Cloud monthly plan | `calendar` | StoreKit display name, localized price, and recurring nature |
| Cloud/BYOK annual plan | `calendar.badge.clock` / `key.fill` | StoreKit display name, localized price, included capability, and recurring nature |
| Restore purchases | `arrow.clockwise` | Restore state and errors in text |
| Continue / close | `arrow.right` / `xmark` | Localized accessibility labels and normal keyboard focus |

All symbols above are present in the installed SF Symbols metadata at release year
2023 or earlier (`name_availability.plist`). PasteBuddy's minimum macOS 26
still accepts that 2023 symbol generation. Implementation must additionally keep a
runtime `NSImage(systemSymbolName:) != nil` test for every mapped name and must not
use a symbol as the only accessible name or state cue.

## Implementation sequence

1. Keep the contextual setup sheet routed through the existing `PasteBuddyStore`;
   do not add a second store or account model.
2. Keep product fetch, `purchasePersonalPlan`, verified transaction updates, and
   `restorePurchases` as the only entitlement paths.
3. Keep API keys in the device-only Keychain and all semantic records/embeddings in
   local SQLite. Provider/model changes must explicitly rebuild derived data.
4. Maintain localized labels, keyboard/VoiceOver navigation, symbol-availability
   tests, and installed stable-bundle purchase sandbox verification.

No custom icon assets, emoji icons, raster symbols, self-made SVG symbols, or
parallel onboarding/paywall window architecture are permitted.
