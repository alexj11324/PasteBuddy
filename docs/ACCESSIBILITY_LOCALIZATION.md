# Accessibility And Localization Baseline

PasteBuddy should behave like a native Apple productivity app for keyboard,
VoiceOver, Dark Mode, and localization workflows.

## Current Implementation

- Main clipboard list rows expose combined VoiceOver labels with title, content
  type, item labels, source app, and copied time.
- Item labels are editable from the detail view and visible on Mac and mobile
  history rows.
- Reusable content categories are editable from the detail view and visible on
  Mac and mobile history rows.
- Filter controls have explicit accessibility labels.
- Active filter chips expose VoiceOver labels and can clear one structured
  filter at a time.
- Editable text previews and save actions expose labels and hints.
- Image previews expose an accessibility label and a contextual
  `text.viewfinder` action that enables native VisionKit Live Text selection
  directly over the hydrated image. The action is absent from persistent
  Shelf, Side Panel, and Settings chrome.
- Pinboard color choices expose VoiceOver labels and selected state, and the
  color picker adds a checkmark in Differentiate Without Color mode.
- Custom capture rule controls in Settings use labeled fields, toggles, and
  localized rule-condition names.
- Direct-paste fallback feedback is exposed as a status bar and Settings status
  text when Accessibility access is missing, including the manual Command-V
  fallback and the request-access action.
- Menu bar status exposes active/paused capture labels, launch-at-login state,
  and named Settings entry points instead of relying only on icon or color
  state.
- Shortcut Settings expose editable keys, modifier checkboxes, clear actions,
  and reset behavior with localized labels.
- Settings uses flexible minimum and ideal sizing instead of a fixed-only frame
  so Larger Text and localized strings have more room.
- Settings exposes a read-only Quality Bar report covering VoiceOver, Larger
  Text, Light/Dark appearance, non-color status cues, and localization
  readiness. The report uses text, icons, and accessible combined labels instead
  of relying on color alone.
- The UI uses system colors, semantic foreground styles, and materials so it
  follows Light/Dark appearance without a fixed custom theme.
- App Intents use `LocalizedStringResource` titles and descriptions for
  Shortcuts-facing strings.
- Localization is maintained through the Dify-backed String Catalog workflow in
  `docs/LOCALIZATION_WORKFLOW.md`.
- The Apple-facing iOS app and extensions consume `Localizable.xcstrings`; the
  SwiftPM app target keeps expanded `Localizable.strings` only as a compatibility
  copy generated from the same workflow.
- Core-generated mobile guidance and keyboard status copy uses semantic
  localization keys through `PasteBuddyLocalization` rather than hard-coded
  English strings.
- Tests assert English and Simplified Chinese resource keys stay in sync,
  priority user-facing strings have Simplified Chinese translations,
  `Localizable.xcstrings` matches the reviewed `.strings` values, and the
  quality report covers the release criteria areas.

## Required Before Release

- Run `python3 script/localization_catalog_workflow.py check` before release to
  block raw English UI literals, missing catalog keys, placeholder drift, and
  String Catalog target membership regressions.
- Run a VoiceOver pass over history browsing, pinboards, settings, Shortcuts,
  and direct-paste permission prompts.
- Add high-contrast checks for pinboard colors and sync/sharing status
  indicators.
- Audit Larger Text behavior in compact settings and list/detail layouts.
