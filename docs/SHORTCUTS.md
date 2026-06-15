# PasteBuddy Shortcuts

PasteBuddy's current SwiftPM macOS build wires keyboard shortcuts through the
app command menu. Core command shortcuts are driven by the encrypted
`ShortcutConfiguration` snapshot and can be edited, cleared, or reset in
Settings.

## Current Defaults

- Quick Paste visible item 1-9: `Command+Option+1` through `Command+Option+9`.
- Plain Text Quick Paste visible item 1-9: `Command+Option+Control+1` through `Command+Option+Control+9`.
- Activate Paste Stack: `Command+Shift+C`.
- Paste Next Stack Item: `Command+Option+V`.
- Reverse Paste Stack: `Command+Option+R`.
- Copy selected PasteBuddy item: `Command+Option+C`.
- Paste selected PasteBuddy item: `Command+Shift+V`.
- Copy selected item as plain text: `Command+Control+C`.
- Paste selected item as plain text: `Command+Control+V`.

## Customization

Settings exposes key and modifier controls for core command shortcuts plus
Quick Paste modifier sets. Clearing a shortcut keeps the menu action available
but removes its keyboard equivalent. Reset Shortcuts restores the defaults above
after reload.

## App Shortcuts

PasteBuddy also registers App Shortcuts for local search, text-item creation,
and copy-first-match automation. See [Automation](AUTOMATION.md).

## Deferred Signed-App Work

The shortcut configuration model stores a show/hide panel binding so a signed
app build can register a system-wide hotkey. The SwiftPM development bundle
does not yet install a global hotkey listener.
