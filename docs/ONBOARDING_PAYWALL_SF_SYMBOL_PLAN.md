# Onboarding and Paywall SF Symbol Plan

## Current-state audit

- PasteBuddy has no dedicated onboarding or paywall view. The only Mac scene is
  native SwiftUI Settings, organized with `NavigationSplitView`, `Form`, `Section`,
  `Toggle`, `Button`, and SF Symbol sidebar labels.
- Accessibility permission is exposed in Settings for direct paste. OCR has a
  Settings toggle; OCR and translation do not yet have first-run/how-to pages.
  Screenshot capture and Screen Recording permission are out of scope.
- The Plans form currently mutates local trial/entitlement state and presents an
  unavailable restore action. The core already has `AppleStoreKitEntitlementProvider`,
  verified transactions, product fetch/purchase/restore, and transaction updates,
  but the current Plans UI does not call that production infrastructure.
- Existing Settings and status-menu affordances already use SF Symbols. Installed
  application icons shown by application pickers are the external apps' real icons,
  not onboarding/paywall artwork, and are outside this constraint.

No onboarding or paywall UI should be added until its state model is routed through
the existing settings, permission, and StoreKit owners above.

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
| Subscription sidebar | `shield` | “Subscription” text label; sidebar state is never icon-only |
| Monthly plan | `calendar` | StoreKit display name and localized price |
| Annual plan | `calendar.badge.clock` | StoreKit display name and localized price |
| Lifetime plan | `infinity` | StoreKit display name and localized price |
| Family plan | `person.2.fill` | StoreKit family-shareability text |
| Restore purchases | `arrow.clockwise` | Restore state and errors in text |
| Continue / close | `arrow.right` / `xmark` | Localized accessibility labels and normal keyboard focus |

All symbols above are present in the installed SF Symbols metadata at release year
2023 or earlier (`name_availability.plist`). PasteBuddy's minimum macOS 14.5
corresponds to the 2023 symbol generation. Implementation must additionally keep a
runtime `NSImage(systemSymbolName:) != nil` test for every mapped name and must not
use a symbol as the only accessible name or state cue.

## Implementation sequence

1. Add one SwiftUI-owned first-run state model persisted in the existing snapshot or
   preferences owner; do not add a second store.
2. Present native pages/sheets using the existing design system. Permission buttons
   call the current Accessibility owner and display live state.
3. Route the paywall through product fetch, `purchasePersonalPlan`, verified
   transaction updates, and `restorePurchases`; remove the current simulated plan
   activation buttons when the real UI is implemented.
4. Add localized labels, keyboard/VoiceOver navigation, symbol-availability tests,
   and installed stable-bundle permission/purchase sandbox verification.

No custom icon assets, emoji icons, raster symbols, self-made SVG symbols, or
parallel onboarding/paywall window architecture are permitted.
