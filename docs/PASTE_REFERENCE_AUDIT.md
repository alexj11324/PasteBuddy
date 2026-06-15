# Paste Reference Audit

Reference captured on 2026-06-15 with the Codex in-app browser against
`https://pasteapp.io`.

## Pages Observed

- Home: product hero centers on a bottom clipboard shelf with compact colored
  cards, search, named pinboards, device sync, privacy, custom rules, preview
  and edit, Siri, iOS keyboard, testimonials, and purchase CTAs.
- Pricing: personal purchase, free trial/download, Setapp option, and trial
  education.
- Teams: shared pinboards, collaboration, team pricing, and team productivity
  positioning.
- MCP: clipboard history as controlled AI context, setup links for Claude,
  Codex, Cursor, and custom MCP clients, plus permission/privacy messaging.
- Use Cases: audience-specific positioning for everyone, developers, designers,
  and content/marketing workflows.

## Product Surface Contract

- The primary interaction is a transient shelf, not a management dashboard.
- The shelf needs a horizontal search-and-collection strip that keeps history,
  paste stack, and pinboards one click away.
- Clipboard entries should read as compact, color-coded cards with immediate
  visual content-type recognition.
- First visible items need keyboard affordances for quick paste.
- Filters should be visible when active and removable without leaving the shelf.
- Management, security, sync, teams, and MCP should remain available in the
  full app and Settings, but should not clutter the shelf's first frame.

## Implemented In This Pass

- Reworked `ClipboardShelfPanelView` into a Paste-like shelf surface.
- Added a horizontal collection strip for Clipboard, Paste Stack, and pinboards.
- Added compact colored cards with first-9 quick paste badge slots.
- Mapped content colors to the observed Paste visual language: text blue, links
  green, images pink, files amber, mixed purple.
- Added active filter chips that can be removed inside the shelf.
- Hid the launch-at-login prompt by default so it no longer occupies the
  product shelf.
- Converted the shelf panel into a bottom-attached, non-draggable sheet using
  `NSScreen.visibleFrame` for adaptive sizing and AppKit frame animation from
  below the screen.
- Changed quick paste labels so first-9 badges appear only while Command is
  pressed, matching Paste's transient shortcut overlay behavior.
- Added shelf multi-select with Command-click toggling, Shift-click range
  selection, selected-count feedback, and grouped drag payloads.

## Remaining Product Gaps

- Add a richer visual preview for links and files that resembles Paste's card
  previews.
- Add an onboarding/import path that seeds realistic starter pinboards without
  polluting normal release data.
- Expand team administration UX beyond Settings metadata.
- Add a dedicated MCP setup wizard that mirrors the observed AI tools page.
- Create signed app packaging, entitlements, App Store products, iCloud
  container wiring, and external billing configuration for production release.
