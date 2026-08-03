# PasteBuddy Linear Implementation Status

This status map covers Linear issues DAY123-26 through DAY123-55 in the
`PasteBuddy: Paste.app Feature Parity` project.

## Implemented In The Local macOS MVP

- DAY123-26: Automatic clipboard history capture for text, links, images,
  multiple files, rich text variants, and mixed pasteboard
  payloads, with normalized metadata, deduplication, and quiet unsupported-type
  handling.
- DAY123-27: Configurable max item count, max age, max encrypted history bytes,
  pinned/unpinned storage usage reporting, capacity pruning that preserves
  pinned items, and safe clear-unpinned vs explicit clear-all-history controls.
- DAY123-28: Visual history browser with fixed-size preview rows, image
  thumbnails, text/link/file/mixed preview summaries, visible source/time/device
  metadata chips, labels, and lazy `List` rendering for long histories.
- DAY123-29: Direct paste to the active Mac app with Accessibility fallback,
  structured paste results, explicit first-attempt permission guidance, a
  manual Command-V fallback explanation, and visible copy-only status feedback.
- DAY123-30: Multi-select paste in visible order with a pre-paste order
  preview, selected item numbering, and clear plain-text fallback messaging for
  multi-item or mixed-content pasteboard writes.
- DAY123-31: Paste Stack with shortcut/menu activation, visible paste-order
  preview, direction toggle, manual item removal, and automatic removal after
  reuse.
- DAY123-32: Global and per-item plain-text paste.
- DAY123-33: Preview, edit, rename, open, single/multi-select delete,
  group undo delete, and manual text item creation.
- DAY123-34: Keyboard-first Quick Paste 1-9, configurable command shortcuts,
  Settings editing for keys/modifiers, cleared shortcut support, and reset to
  defaults.
- DAY123-35: Full-text search across history, pinboards, labels, and OCR
  metadata.
- DAY123-36: Filters by source app, content type, copied date, and device,
  including generated search suggestions and visible removable active-filter
  chips on Mac and mobile browsing surfaces.
- DAY123-37: Local Apple Vision OCR after clipboard image capture, with OCR
  text saved as searchable encrypted metadata.
- DAY123-38: User-editable item titles and labels, with labels normalized,
  encrypted, searchable, persisted through paste-stack edits, and visible on
  Mac/mobile item rows.
- DAY123-39: Named, color-coded, reorderable pinboards.
- DAY123-40: Pin, move, reorder, and remove items inside pinboards.
- DAY123-41: Shared pinboard owner, invite, participant, permission, link-token
  hash, Curve25519/AES-GCM board-key wrapping, public identity records,
  recipient-scoped invitation packages, CloudKit invitation record adapter,
  silent invitation query subscriptions, encrypted pending-invitation inbox,
  background refresh service, CloudKit notification subscription router,
  delivery transport seam, participant acceptance, and stop-sharing metadata
  behind encrypted sync gates.
- DAY123-42: Reusable mixed-content collections through pinboards, reusable
  content categories for snippets, templates, code, colors, and assets, manual
  item creation, search, Quick Paste, and plain-text copy/paste.
- DAY123-43: Encrypted CloudKit package builder/importer, remote record
  transport boundary, real CloudKit transport adapter, readiness gates,
  conflict merge reporting, local preflight diagnostics, recovery
  recommendations, and no plaintext fallback.
- DAY123-47: App Intents for local search, text-item creation, copying the
  first matching item, creating pinboards, and saving the first matching item to
  a named pinboard.
- DAY123-49: Privacy controls, content-type toggles, sensitive app exclusions,
  timed/indefinite pause, local sensitive-text blocking, and encrypted custom
  capture rules for text, regex, source app, bundle identifier, URL host, and
  file-extension blocking across capture, shared import, and Shortcuts item
  creation. Manual history entry now uses the same privacy decision path before
  writing to history, pinboards, or search, and `PrivacyPostureReport` exposes
  paused state plus protected-surface coverage for history, pinboards, search,
  Shortcuts, keyboard, Share/Action, and MCP access.
- DAY123-50: Menu bar status, launch-at-login preference, and
  Settings sections. The menu bar now uses a tested `MacMenuBarStatus` model for
  active/paused title, icon, capture action, launch-at-login state, quick access
  to the main window, and Settings entry points for General, Shortcuts, Privacy,
  Sync, and Storage.
- Paste reference pass: the transient clipboard shelf now matches the observed
  Paste product surface more closely with a horizontal search-and-collection
  strip, compact color-coded cards, Command-only first-9 quick paste badges,
  shelf multi-select, inline active filter removal, and default removal of the
  launch-at-login prompt from the shelf's first frame. The shelf is now a
  bottom-attached non-draggable `NSPanel` that sizes from `NSScreen.visibleFrame`
  and animates in/out from the bottom edge instead of floating above the main
  app window.
- DAY123-51: Local stdio MCP server with per-tool opt-in, summary-only
  clipboard search, explicit opt-in item payload retrieval, and pinboard
  actions, encrypted metadata-only access audit logging, and generated setup
  snippets for Codex, Claude Desktop, Cursor, VS Code, Windsurf, and custom MCP
  clients. MCP search, retrieve, pinboard counts, and pin-first-match now
  re-apply current local privacy rules at read time so later capture-rule or
  content-type changes also hide existing history from AI tools.
- DAY123-52: Team plan metadata for seats, per-seat pricing, managed
  distribution, single invoice, admin state, and team positioning. The team
  overview model and Settings copy distinguish Team from personal plans and
  center the value proposition on shared pinboards for ideas, links, files,
  images, snippets, and staying in sync.
- DAY123-53: Trial, monthly, annual, lifetime, family, restore, all-devices
  entitlement model, StoreKit product configuration, StoreKit 2 purchase/restore
  adapter, transaction update observer, verified entitlement mapping, and a
  Settings-facing personal entitlement overview covering trial reminders/trial
  end behavior, same-account Mac/iPhone/iPad unlocks, restore guidance for
  reinstall/device changes, purchase option summaries, and encrypted
  billing-safety boundaries.
- DAY123-54: VoiceOver labels on core flows, semantic appearance, Differentiate
  Without Color pinboard selection, flexible Settings sizing, and initial
  English/Simplified Chinese localization resources with parity tests for
  priority Mac, mobile, filtering, Settings, MCP, sync, extension setup, and
  monetization strings. Settings now includes a tested Quality Bar report for
  VoiceOver, Larger Text, Light/Dark appearance, non-color status cues, and
  localization readiness.
- DAY123-55: User-visible standard vs AES-GCM encrypted local storage modes,
  non-interactive Keychain key lookup to avoid surprise login-keychain prompts,
  optional Touch ID history lock with a grace period, this-device-only Keychain
  key, optional Secure Enclave key wrapping, legacy plaintext snapshot migration
  into encrypted mode, default startup that does not auto-open legacy `.pbenc`
  stores, local key rotation by re-encryption, safe unreadable-store handling,
  encrypted sync packages, encrypted shared pinboard metadata,
  encrypted entitlement metadata in encrypted mode, encrypted MCP access audit
  metadata in encrypted mode, code-level encryption coverage audit, and
  documented threat model/downgrade rules.

## Implemented Mobile Targets

- DAY123-44: Native iPhone and iPad app. `PasteBuddyiOS.xcodeproj` now provides
  the `PasteBuddyiOS` scheme, a SwiftUI app lifecycle, simulator Info.plist and
  entitlement files, and a native browser shell using `MobileClipboardBrowserView`
  with search, filters, pinboards, setup guidance, copy actions, and manual text
  item creation.
- DAY123-45: iOS keyboard extension. `PasteBuddyKeyboard` is embedded in the
  iOS app, exposes `com.apple.keyboard-service`, requests Open Access, embeds
  `MobileKeyboardHistoryView`, and wires `MobileKeyboardPasteService` to
  `textDocumentProxy.insertText(_:)`. Simulator verification added the keyboard
  from Settings and reached the Full Access switch; the system switch itself is
  user-controlled and not toggled by automated tests.
- DAY123-46: iOS Share and Action extensions. `SharedContentImportService`
  imports text, links, files, and images into encrypted history or a pinboard;
  `MobileItemProviderAdapter` maps `NSItemProvider` payloads into shared import
  inputs; `PasteBuddyShareExtension` exposes the Share sheet surface as "Save
  to PasteBuddy"; `PasteBuddyActionExtension` exposes the Action surface as
  "Copy to PasteBuddy"; both targets share `ShareActionViewController`, use the
  App Group encrypted store path, and are embedded in the simulator
  `PasteBuddyiOS.app`.
- DAY123-48: iOS paste permission onboarding. Shared state and onboarding steps
  exist for Ask/Allow/Denied and keyboard Full Access; the shared guidance
  report explains Allow Paste From Other Apps, withholds automatic capture until
  Allowed, and keeps denied/ask states non-fatal for browsing and manual
  share/action imports. The iOS app target can render the setup guidance; final
  settings deep links remain dependent on iOS Settings behavior.

## External Configuration Still Required

- Apple developer signing, bundle identifiers, app groups, iCloud/CloudKit
  containers, extension entitlements, and App Store products.
- App Store Connect product setup and optional server-side entitlement reconciliation.
- A matching macOS CloudKit provisioning profile, deployed shared-pinboard public
  database schema, push/background registration for invitation subscriptions,
  and account/corruption/lost-key recovery UX beyond local preflight
  diagnostics.
- VoiceOver, high-contrast, Larger Text, and localized UI passes on real macOS,
  iPhone, and iPad builds.
