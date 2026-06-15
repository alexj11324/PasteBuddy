# PasteBuddy Automation

PasteBuddy exposes a small App Intents surface for Shortcuts and Siri-capable
system surfaces in the macOS SwiftPM build.

## Current App Shortcuts

- Search PasteBuddy Clipboard: searches local encrypted history and returns
  matching item titles, not raw payload text.
- Create PasteBuddy Text Item: creates a local encrypted text item and reuses
  PasteBuddy's local sensitive-text blocking rules.
- Copy First PasteBuddy Match: finds the first matching item and copies it to
  the system pasteboard, with an optional plain-text mode.
- Paste First PasteBuddy Match: finds the first matching item, copies it to the
  pasteboard, and asks macOS to insert it into the frontmost app. When
  Accessibility access is missing, PasteBuddy reports the copy-only fallback.
- Create PasteBuddy Pinboard: creates a local encrypted pinboard with optional
  color hex input.
- Create PasteBuddy Content Item: creates a local encrypted text, URL, or file
  URL item and can immediately save it to a named pinboard.
- Save PasteBuddy Match to Pinboard: finds the first matching local item and
  saves it to a named pinboard.

## Privacy Boundaries

- Actions load the local encrypted store on this Mac.
- No vendor server, cloud service, or remote model receives clipboard payloads.
- Search action responses use summary metadata only.
- Copy and paste actions return item summaries and status text only; the raw
  payload is written to the pasteboard/frontmost app but is not echoed in
  Shortcuts result dialogs.
- Creating a text item from Shortcuts is blocked when the text matches local
  sensitive-content heuristics.
- Creating URL/file/text content from Shortcuts respects disabled content-type
  capture toggles and custom capture rules.
- Shortcuts item creation shares the same privacy decision path used by manual
  history entry and Share/Action imports before anything reaches history,
  pinboards, or search.
- Pinboard actions mutate only the local encrypted snapshot. They do not enable
  sync or shared pinboards unless the user separately configures those features.

## Deferred Work

- Entity-backed item and pinboard pickers for richer Shortcuts parameters.
- App launch/routing handoff for opening a specific item or pinboard.
- Voice-trigger phrasing review after localization strings exist.
