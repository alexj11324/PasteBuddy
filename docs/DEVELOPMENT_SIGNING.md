# Apple signing channels

PasteBuddy uses separate signing and delivery channels. Signing proves the
identity of a built artifact; the Git branch controls where that artifact may be
promoted, not whether Xcode or `codesign` can sign it.

| Channel | Identity | Bundle ID | Allowed source | Destination |
| --- | --- | --- | --- | --- |
| Development package | Apple Development, Team `72UN4PF4BL` | `com.alexjiang.PasteBuddy.dev` | Any committed branch | `dist/`, never installed or launched |
| Stable Dev promotion | Apple Development, Team `72UN4PF4BL` | `com.alexjiang.PasteBuddy.dev` | Clean `codex/integrated-delivery` | `/Applications/PasteBuddy Dev.app` |
| TestFlight | Apple distribution managed by Xcode | iOS production identifiers | Exact protected `main` SHA | App Store Connect |
| Developer ID | Developer ID Application, Team `72UN4PF4BL` | `com.alexjiang.PasteBuddy` | Existing `v<semver>` tag contained in protected `main` | Notarized GitHub Release |

Ad-hoc signing, `-`, and Sign to Run Locally are not accepted by any channel.

## Feature branch development package

An arbitrary committed branch can produce a signed package without switching
to `main` or `codex/integrated-delivery`:

```bash
PASTEBUDDY_CODESIGN_IDENTITY=<apple-development-sha1> \
  script/build_and_run.sh --package
```

The output name includes the signing channel and source commit. It is not
installed or launched, so it cannot overwrite the stable Dev app or touch its
data directory.

The configured keychain currently contains more than one valid Apple
Development identity. That is intentionally treated as ambiguous. Select a
certificate by its SHA-1 hash from:

```bash
security find-identity -v -p codesigning "$(security default-keychain -d user | tr -d '\" ')"
```

Certificate hashes and Team IDs are identifiers, not secrets. Private keys stay
in Keychain and must never be copied into the repository.

## Stable Dev promotion and TCC validation

Only a clean `codex/integrated-delivery` checkout may run:

```bash
PASTEBUDDY_CODESIGN_IDENTITY=<apple-development-sha1> \
  script/build_and_run.sh --verify
```

This is the only command allowed to replace `/Applications/PasteBuddy Dev.app`.
A successful runtime acceptance includes:

```text
accessibilityTrusted=true
stableLaunchPathMatched=true
bundleIdentifier=com.alexjiang.PasteBuddy.dev
bundlePath=/Applications/PasteBuddy Dev.app
signingChannel=development
```

The app must also pass:

```bash
codesign --verify --deep --strict --verbose=4 '/Applications/PasteBuddy Dev.app'
codesign -dvvv -r- '/Applications/PasteBuddy Dev.app'
```

Do not use a temporary bundle, raw SwiftPM executable, or a different path as
evidence for Accessibility/TCC persistence.

## Identity resolution rules

`script/build_and_run.sh` only searches `PASTEBUDDY_CODESIGN_KEYCHAIN`, or the
user default keychain when that variable is absent. It requires:

- the correct certificate class for the selected channel;
- an available private key;
- exactly one matching identity unless a SHA-1 hash is provided;
- Team ID `72UN4PF4BL` after signing;
- the expected Bundle ID and designated requirement;
- a matching, currently valid provisioning profile for CloudKit and shared
  Keychain entitlements.

Wrong or ambiguous inputs fail closed. Repository scripts do not unlock a
developer's normal keychain or change its partition list.

## Developer ID release

Do not use `PASTEBUDDY_SIGNING_CHANNEL=release script/build_and_run.sh --verify`.
A Developer ID signature alone is not a distributable release. The only formal
release entrypoint is `.github/workflows/macos-release.yml`, which calls
`script/release_macos.sh` and requires all of the following to pass:

1. nested-code-first signing with `--options runtime --timestamp`;
2. strict `codesign` verification and Team/Bundle/entitlement checks;
3. Apple notarization with an accepted result and retrieved log;
4. ticket stapling and `stapler validate`;
5. Gatekeeper `spctl --assess`;
6. SHA-256 and provenance generation;
7. publication of only the final stapled ZIP to the matching GitHub Release.

See `docs/MACOS_RELEASE_AND_RUNNERS.md` for credential provisioning, runner
setup, rotation, and rollback.
