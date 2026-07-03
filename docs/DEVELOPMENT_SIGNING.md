# Development Signing

Use the project run script for macOS development builds:

```bash
script/build_and_run.sh --verify
```

This is the stable development path. It builds the SwiftPM app, signs a
`PasteBuddy Dev.app` bundle with an `Apple Development` identity, installs it at
`/Applications/PasteBuddy Dev.app`, prints runtime diagnostics, and opens the
fresh app.

## Expected Result

A successful run includes:

```text
Installed /Applications/PasteBuddy Dev.app signed with <identity> (development, com.alexjiang.PasteBuddy.dev)
accessibilityTrusted=true
stableLaunchPathMatched=true
bundleIdentifier=com.alexjiang.PasteBuddy.dev
bundlePath=/Applications/PasteBuddy Dev.app
signingChannel=development
```

`PasteBuddyCodeSigningIdentity` in the installed app's `Info.plist` records the
identity used for that build.

## Keychain Rules

The script must not use ad-hoc signing, a raw SwiftPM executable, or a temporary
app bundle as proof for Accessibility/TCC behavior.

For development signing, the script resolves identities only from the configured
code-signing keychain:

1. `PASTEBUDDY_CODESIGN_KEYCHAIN`, when set.
2. The user default keychain from `security default-keychain -d user`.

It passes that same keychain to `codesign --keychain`, so another project's
local keychain in the user search list cannot be selected accidentally.

Do not add `security unlock-keychain` or `security set-key-partition-list` to
this repo script. If macOS asks for a Keychain password during normal
development builds, treat that as local machine setup drift, not as a build step
to automate in the repository.

## When The Script Fails

If no signing identity is found, install or select a valid `Apple Development`
identity in the user default keychain, or point the script at a local keychain:

```bash
PASTEBUDDY_CODESIGN_KEYCHAIN=/path/to/local.keychain-db script/build_and_run.sh --verify
```

If multiple identities exist, the script still requires a stable non-ad-hoc
identity. You can pin one for a single run without storing secrets:

```bash
PASTEBUDDY_CODESIGN_IDENTITY=<certificate-sha1> script/build_and_run.sh --verify
```

The certificate hash is not a secret. Private keys must stay in Keychain and
must not be committed to the repository.

## Release Signing

Development builds use `Apple Development` with:

- app name: `PasteBuddy Dev`
- bundle id: `com.alexjiang.PasteBuddy.dev`
- install path: `/Applications/PasteBuddy Dev.app`

Release or real user-path verification must use:

```bash
PASTEBUDDY_SIGNING_CHANNEL=release script/build_and_run.sh --verify
```

Release signing requires a `Developer ID Application` identity. The script must
fail rather than falling back to ad-hoc signing.
