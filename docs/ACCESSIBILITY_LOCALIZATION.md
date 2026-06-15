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
- Image previews expose an accessibility label and point users toward local OCR
  text when available.
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
- The SwiftPM app target includes expanded `Localizable.strings` resources for
  English and Simplified Chinese across core Mac, mobile browsing, filtering,
  settings, MCP, sync, and extension setup surfaces.
- Tests assert English and Simplified Chinese resource keys stay in sync,
  priority user-facing strings have Simplified Chinese translations, and the
  quality report covers the release criteria areas.

## Required Before Release

- Continue expanding localization coverage for dynamic/interpolated strings and
  move remaining low-level status copy into the resource catalog.
- Run a VoiceOver pass over history browsing, pinboards, settings, Shortcuts,
  and direct-paste permission prompts.
- Add high-contrast checks for pinboard colors and sync/sharing status
  indicators.
- Audit Larger Text behavior in compact settings and list/detail layouts.
