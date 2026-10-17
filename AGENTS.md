# PasteBuddy Agent Rules

Keep changes scoped to PasteBuddy and preserve unrelated working-tree state.
Detailed product contracts live in
`docs/agent-guides/product-runtime-contracts.md`; read only the sections named
below when the task enters that branch.

## Durable repository rules

- An explicit request to remove a feature means removing its implementation,
  references, state, and layout ownership. Preserve it behind a flag only when
  the user asks for a temporary or reversible disablement.
- Disposable smoke and probe files belong in a temporary directory. Persist a
  test only when it is an intentional regression gate.
- User-visible strings use semantic keys in
  `Sources/PasteBuddy/Resources/Localizable.xcstrings`. Read the localization
  section of the product contracts before changing copy or catalogs.
- Clipboard sync uses the encrypted CloudKit private-database path. Iroh has
  been removed, including its implementation, dependency, pairing state, and
  UI. Read the iCloud clipboard sync section before changing sync availability.
- Secrets use the configured `gsm` / `general-secrets-store` workflow and
  never enter tracked files or long-lived plaintext configuration.

## Runtime and UI branches

- For macOS window, panel, Shelf, Side Panel, hit-testing, focus, drag, or visual
  work, read the macOS UI/HID, Shelf, visual-boundary, and signing sections of
  the product contracts.
- For image, OCR, translation, Onboarding, permission, or Paywall work, read the
  matching ownership section before editing.
- For integrated delivery across macOS/iOS/extensions, read the integration
  section before selecting targets or declaring completion.

Runtime acceptance uses the stable signed development app and real window/view
geometry. A build alone does not complete a user-visible fix; exercise the
affected interaction and report any missing visual verification explicitly.

## Release branches

- For iOS or TestFlight release work, read the TestFlight section of the product
  contracts and use `script/push_testflight.sh`.
- For App Store Connect CLI work, consult `ASC.md` for commands rather than
  copying its catalog into this file.
