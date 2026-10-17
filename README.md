# PasteBuddy

PasteBuddy is a local-first macOS clipboard manager scaffold aimed at
Paste.app-style workflows.

## Current focus

- standard local clipboard history with optional AES-GCM encryption and Touch
  ID history lock
- configurable retention, storage size limits, pinned/unpinned usage
  reporting, and safe clear-history controls
- text, URL, multi-file, image, rich text, and mixed clipboard payload capture
- visual history rows with image thumbnails, readable text/link/file previews,
  labels, source app, copied time, and device metadata
- local Apple Vision OCR immediately after image capture
- search, generated filter suggestions, active filter chips, and structured
  filters over decrypted in-memory history and OCR metadata
- preview, edit, label, reusable snippet/template/code/color/asset
  categorization, open link/file, create manual text items, single/multi-select
  delete, and group undo delete
- pinboards for reusable collections, including rename, recolor, reorder,
  drag-to-pin from history, item move, and item removal without deleting history
- Paste Stack for collecting copied items and pasting them back in order
- multi-select copy and paste in visible order, with an on-screen paste-order
  preview and multiple mixed items pasted as plain text
- keyboard-first Quick Paste for the first 1-9 visible items, plain-text Quick
  Paste variants, and Settings-editable command shortcuts with clear/reset
  behavior
- Shortcuts/App Intents actions for local search, encrypted text/URL/file item
  creation, copy-or-paste-first-match, pinboard creation, and save-match-to-
  pinboard automation
- local stdio MCP server with per-tool opt-in for summary search, explicit
  item retrieval, pinboard actions, encrypted metadata-only access audit
  logging, and generated client setup snippets
- local entitlement model and Settings overview for trial reminders, trial end
  behavior, monthly, annual, lifetime, family, restore purchases, same-account
  Mac/iPhone/iPad unlocks, and team seat packaging with shared-pinboard team
  positioning
- native Mac utility controls including active/paused menu bar status,
  launch-at-login preference, and menu bar entry points for General,
  Shortcuts, Privacy, Sync, and Storage settings
- VoiceOver-oriented labels for core history rows, filters, previews, and OCR
  image surfaces
- expanded English and Simplified Chinese localization resources with parity
  tests, a Settings Quality Bar report, plus Differentiate Without Color
  support for pinboard color selection
- paste as plain text globally or per item without changing the saved original
  item
- privacy controls for timed or indefinite pause, content-type capture
  toggles, local sensitive-text blocking, custom local capture rules, excluded
  apps by name or bundle identifier, and a shared privacy posture report across
  history, pinboards, search, Shortcuts, keyboard, Share/Action, and MCP access
- existing local-first sync/sharing gates, Mac/iOS shared pinboard management,
  encrypted sync package import/merge, shared pinboard permission metadata,
  wrapped board-key exchange, invitation packages, encrypted pending-invitation
  inbox, and CloudKit-backed invitation record/subscription adapters as
  migration inputs; they are not the new cloud authority
- shared-core iOS/iPadOS integration state and permission guidance for paste
  onboarding, keyboard/share/action extension enablement, and extension
  content import
- PasteBuddyMobile SwiftUI library for reusable iPhone/iPad browsing with
  adaptive split view, search/filter chips, full-screen preview, context menus,
  copy/plain-text copy, iPad drag-to-pinboard, mobile setup guidance, keyboard
  history/pinboards with Full Access guidance and insertion service, Share/Action
  extension import into encrypted history or pinboards, and iOS pasteboard
  writing
- basic copy and direct-paste workflows, with macOS Accessibility access
  required only for automatic Command-V injection and visible copy-only
  fallback feedback

## Build

    swift build

## Test

    swift test

## Run

    ./script/build_and_run.sh

The run script builds the SwiftPM app, signs and installs
/Applications/PasteBuddy Dev.app, prints runtime diagnostics, and launches it
as a foreground macOS app. Use ./script/build_and_run.sh --verify when you
need stable signing and Accessibility/TCC proof. See
[Development Signing](docs/DEVELOPMENT_SIGNING.md).

## macOS Permissions

Direct paste always copies the selected item to the system pasteboard first.
To also paste automatically into the frontmost app, grant PasteBuddy
Accessibility access in System Settings. The Settings window includes a
direct permission prompt entry point, and the main window explains that
copy-only fallback still lets the user paste manually with Command-V.

## Sync

PasteBuddy remains fully usable in local-only mode. The target cloud
architecture is PowerSync plus Supabase: PowerSync owns one managed SQLite
authority, the main app owns one connection, and extensions write only an
encrypted App Group handoff. Sensitive and excluded content has zero network
path. Cloud content is service-readable under Auth/RLS and is not E2EE.

The [Cloud Sync and AI Refactor Plan](docs/architecture/PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md)
is the sole authority for implementation scope and order. ADR-002 controls
architecture decisions, the schema contract controls data boundaries, and the
acceptance matrix controls proof. WP1 is a hard stop before migration.

Cloud quotas are 5,000 clipboard items and 250,000,000 attachment bytes.
Backfill prioritizes the newest 100 eligible items and continues resumably.
Clipboard sync uses encrypted CloudKit private-database snapshots in
`iCloud.com.alexjiang.PasteBuddy`. The user turns iCloud sync on explicitly,
and macOS, iOS, and the keyboard, share, and action extensions share that
path. Iroh has been removed. Once the PowerSync migration is in place, those
CloudKit snapshots become a one-time recovery input and stay read-only for 90
days; they are not a second authority beside PowerSync.

## Shortcuts

The macOS app command layer includes Quick Paste for the first 1-9 visible
items. Default shortcuts are documented in
[Shortcuts](docs/SHORTCUTS.md). Shortcuts and Siri-capable system surfaces are
documented in [Automation](docs/AUTOMATION.md).

## Quality Bar

Accessibility and localization readiness notes are tracked in
[Accessibility And Localization Baseline](docs/ACCESSIBILITY_LOCALIZATION.md).
The Dify-backed String Catalog maintenance flow is documented in
[Localization Workflow](docs/LOCALIZATION_WORKFLOW.md).

## iOS And iPadOS

The PasteBuddyiOS.xcodeproj host builds a native iPhone/iPad browser app and
embeds the PasteBuddy keyboard, Share, and Action extensions. Shared-core
models and signed-release configuration notes are documented in
[iOS And iPadOS Integrations](docs/IOS_INTEGRATIONS.md). The SwiftPM app target
remains the runnable macOS shell.

## MCP

Local AI tool access is provided by the PasteBuddyMCP executable and documented
in [MCP](docs/MCP.md). MCP is disabled by default and each tool has its own
permission toggle in Settings. Any future remote MCP action must revalidate
authorization before and after every remote await.

## Monetization

Users sign in before purchasing. The Supabase UUID is the RevenueCat App User
ID; canonical RevenueCat CustomerInfo is reconciled to Supabase entitlements,
which are the cloud authorization truth. Existing StoreKit/product mappings
remain migration inputs. See [Monetization And Team Plans](docs/MONETIZATION.md).

## Linear Backlog Status

Implementation coverage for DAY123-26 through DAY123-55 is tracked in
[PasteBuddy Linear Implementation Status](docs/IMPLEMENTATION_STATUS.md).
