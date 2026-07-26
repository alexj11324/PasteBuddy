# Localization Workflow

PasteBuddy follows Apple's String Catalog localization path. User-facing app
strings live in one authoritative `Localizable.xcstrings`, consumed directly by
the macOS SwiftPM app and every iOS target. Dify uses temporary `.strings`
interchange files outside the repository; they are never app resources.

The maintained resources are:

- `Sources/PasteBuddy/Resources/Localizable.xcstrings`

Use semantic keys in code. Do not use complete English sentences as keys.
Do not add `Localizable.strings` back to any target or package resource.

## Daily Commands

Preview strings that need translation without changing files:

```sh
python3 script/localize_string_catalog_with_dify.py --mode scan
```

Run the Dify workflow, apply translations, regenerate `.xcstrings`, and validate
the result:

```sh
python3 script/localize_string_catalog_with_dify.py
```

Validate the catalog and optionally rewrite Swift call sites without calling Dify:

```sh
python3 script/localize_string_catalog_with_dify.py --skip-dify
```

Validate without changing files:

```sh
python3 script/localization_catalog_workflow.py check
```

## Adding New UI Copy

Add user-facing strings with semantic keys:

```swift
Text("home.empty.title")
Button("action.create_pinboard") { ... }
Text(String(format: NSLocalizedString("format.items_count", comment: ""), count))
```

For strings produced in `PasteBuddyCore` or another non-view layer, use
`PasteBuddyLocalization` with an English fallback:

```swift
PasteBuddyLocalization.string(
    "mobile.keyboard_paste.status_empty_selection",
    defaultValue: "Select a saved item before inserting from the keyboard."
)
```

The fallback must match the English catalog value. The checker fails if the key
is missing or the fallback drifts.

For count-based copy, follow Apple's pluralization guidance instead of using
`item(s)` or another English-only shortcut. Prefer existing singular/plural keys
or add paired semantic keys before syncing the catalog.

For device- or width-specific wording, add the variants in the String Catalog
workflow rather than branching visible English literals in Swift.

## Apple Localization QA

Before treating a localization pass as release-ready:

- Build the catalog so Xcode or `xcstringstool` proves it compiles.
- Test every supported language and region, currently `en` and `zh-Hans`.
- Run a pseudolanguage or double-length pass for layout expansion.
- Run a right-to-left pseudolanguage pass before adding any RTL locale.
- Localize app and extension `InfoPlist.strings` / purpose strings together with
  visible app copy.

## Dify And Secrets

`script/localize_with_dify.py` reads the workflow API key from:

- env var: `DIFY_WORKFLOW_API_KEY`
- fallback secret: `general-secrets-store/dify-pastebuddy-localization-workflow-api-key`

Do not write the Dify API key into the repo, `.env`, generated JSON, or long-lived
local files.

Useful Dify modes:

```sh
python3 script/localize_string_catalog_with_dify.py --mode translate --output tmp/localization-dify-result.json
python3 script/localize_string_catalog_with_dify.py --mode apply --input-result tmp/localization-dify-result.json
python3 script/localize_string_catalog_with_dify.py --workflow-mode full_app --include-existing
python3 script/localize_string_catalog_with_dify.py --workflow-mode review_only --include-existing
```

Keep generated review JSON under `tmp/` unless it is intentionally needed as a
formal release artifact.

## Validation Gates

Before committing localization changes, run:

```sh
python3 script/localization_catalog_workflow.py check
swift test --filter LocalizationResourceTests
swift test
```

The catalog checker verifies:

- English and Simplified Chinese catalog coverage.
- Placeholder parity across locales.
- `Localizable.xcstrings` JSON shape and semantic keys.
- Apple `xcstringstool` can compile `Localizable.xcstrings` for `en` and
  `zh-Hans`.
- no duplicate `Localizable.strings` source or SwiftPM resource declaration exists.
- all targets use `Localizable.xcstrings` in resource phases.
- Swift call sites use semantic keys instead of raw English UI literals.
- `PasteBuddyLocalization` fallbacks match the English catalog value.

For release or full iOS target validation, also run the simulator build:

```sh
xcodebuild -project PasteBuddyiOS.xcodeproj -scheme PasteBuddyiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath tmp/PasteBuddyiOSDerivedData CODE_SIGNING_ALLOWED=NO build
```

## What Should Stay English

Do not translate brand names, shortcuts, or technical terms that users expect to
see as-is:

- `PasteBuddy`
- `Command`, `Option`, `Shift`, `Control`
- `HTML`, `MCP`, `URL`

User content is not App UI copy. Clipboard item titles, pinboard names, source
app names, file names, URLs, OCR text, and user-entered labels should display as
the user created them.
