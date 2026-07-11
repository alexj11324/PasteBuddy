# TestFlight CI

Pull requests targeting `main`, pushes to `main`, and manual dispatches run `.github/workflows/testflight.yml` on GitHub's `macos-26` image.

Every event starts with a read-only `verify` job that does not receive cloud or App Store Connect credentials. It:

1. Runs `swift test`.
2. Verifies the macOS SwiftPM app privacy resource bundle.
3. Checks the localization catalogs.
4. Compiles the Debug app and all embedded extensions for a generic iOS
   Simulator with signing disabled, then verifies each bundle's app-owned and
   embedded GRDB privacy manifests plus the host app's exported UTI. The check
   explicitly reports that Iroh 1.0.0 ships no privacy manifest; it does not
   claim required-reason API coverage for that binary.
5. Compiles the Release app and all embedded extensions for generic iOS with
   signing disabled, then repeats the built-artifact checks.

The Xcode project uses Swift 6 with complete strict concurrency checking for the iOS app, keyboard, share, and action targets. SwiftPM tests remain a plain `swift test`; do not force third-party package targets into Swift 6 with a global compiler flag. Aligning and committing an authoritative Xcode package-resolution file remains Task 9 work; until then, the Xcode verification builds use normal package resolution instead of requiring an untracked workspace file.

Only a successful push to `main` or a manual dispatch of `main` unlocks the `upload` job. A manual dispatch from another ref still verifies that ref, but cannot receive GCP or App Store Connect credentials. The upload job alone receives `contents: write` and `id-token: write`, and actual uploads are serialized. It:

1. Authenticates to Google Cloud with GitHub OIDC.
2. Restores the App Store Connect API key from Google Secret Manager.
3. Queries App Store Connect for the latest uploaded build on app `6780560937`.
4. Compares that number with the highest `ios-build-*` git tag.
5. Archives `PasteBuddyiOS` with `CURRENT_PROJECT_VERSION` set to the next integer.
6. Repeats the same scoped privacy checks against the archived host app and all
   embedded extensions before export.
7. Uploads the archive to App Store Connect for TestFlight processing.
8. Persists the uploaded build number as an `ios-build-<number>` git tag.

## Manual Encryption Export Gate

Privacy-manifest checks are automated, but encryption export classification is
not. Before the next upload, the App Store Connect account holder must resolve
the checklist in `docs/SECURITY.md`, including the linked Iroh/Rust
cryptography and intended French distribution. The repository currently leaves
`ITSAppUsesNonExemptEncryption=false` in all four iOS Info.plists; CI must not
present that existing value as a newly verified legal determination.

If Apple requires documentation, upload it through App Store Connect. Add an
`ITSEncryptionExportComplianceCode` only after Apple issues the code; never put
account credentials, `.p8` keys, or private compliance documents in the
repository.

Required GitHub Actions secrets:

- `ASC_KEY_ID`: App Store Connect API key ID, currently `664UJQLMB2`.
- `ASC_ISSUER_ID`: App Store Connect issuer ID.

The `.p8` private key is not stored in GitHub. It stays in Google Secret Manager as `asc-api-key-664UJQLMB2` in project `general-secrets-store`.

GitHub OIDC access is scoped to this provider and service account:

- `projects/320884539284/locations/global/workloadIdentityPools/github-actions/providers/pastebuddy`
- `pastebuddy-github-actions@general-secrets-store.iam.gserviceaccount.com`

The Apple team ID and App Store Connect app ID are committed in the workflow because they are identifiers, not secrets:

- Team ID: `72UN4PF4BL`
- App Store Connect app ID: `6780560937`

The build number is not committed back to the repository. It is resolved at upload time from App Store Connect, then incremented by one.

`ios-build-*` tags store successful CI-uploaded build numbers. The workflow uses `max(App Store Connect latest, highest ios-build tag) + 1`, which avoids a duplicate build number if App Store Connect has accepted an upload but has not listed the new build yet.
