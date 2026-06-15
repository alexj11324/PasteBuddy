# TestFlight CI

Pushing to `main` runs `.github/workflows/testflight.yml`.

The workflow runs on GitHub's `macos-26` image so archives are built with Xcode 26 and the iOS 26 SDK required by App Store Connect.

The workflow:

1. Authenticates to Google Cloud with GitHub OIDC.
2. Restores the App Store Connect API key from Google Secret Manager.
3. Queries App Store Connect for the latest uploaded build on app `6780560937`.
4. Archives `PasteBuddyiOS` with `CURRENT_PROJECT_VERSION` set to the next integer.
5. Uploads the archive to App Store Connect for TestFlight processing.

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
