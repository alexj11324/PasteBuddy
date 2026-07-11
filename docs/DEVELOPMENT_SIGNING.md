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

### Iroh macOS 14.5 Release Blocker

The upstream Iroh 1.0.0 release xcframework is not currently compatible with
PasteBuddy's macOS 14.5 deployment floor. Object-level inspection of the
published macOS archive on 2026-07-11 found:

- 366 objects with minOS 11.0;
- 25 objects with minOS 14.5;
- `a1edd97dd51cd48d-blake3_neon.o` with minOS 26.5.

That last object is the source of the linker warning and makes a macOS 14.5
release claim unverifiable. The issue is consistent with the BLAKE3 Apple
cross-compilation failure documented in
[BLAKE3 issue 437](https://github.com/BLAKE3-team/BLAKE3/issues/437).

A clean build from the official Iroh tag `v1.0.0` (`afcb46d`) using its locked
dependencies and `MACOSX_DEPLOYMENT_TARGET=14.5` produced a macOS archive with
375 objects at minOS 11.0 and 26 at minOS 14.5. Its 350 exported UniFFI symbols
matched the published archive exactly. This proves the source can produce a
compatible slice, but it is not a distributable replacement: the tag does not
pin the Rust toolchain, the locally rebuilt archive is not covered by the
published xcframework checksum, and no upstream release contains that rebuilt
full Apple artifact. PasteBuddy therefore does not vendor or copy the local
binary into `.build`.

Release packaging runs this mandatory gate after SwiftPM resolution:

```bash
script/verify_iroh_macos_minimum_os.sh \
  "$(swift build --show-bin-path)/Iroh.framework/Iroh" 14.5
```

Development builds remain available, but
`PASTEBUDDY_SIGNING_CHANNEL=release script/build_and_run.sh --verify` must fail
until the resolved upstream archive passes. Do not hide the warning or raise
PasteBuddy's deployment target to match the accidental object version.

To clear the blocker:

1. Upgrade to an official Iroh release whose published checksum covers a fixed
   xcframework.
2. Resolve from a clean SwiftPM cache and run the gate above.
3. Confirm the UniFFI export set still matches the generated Swift bindings.
4. Run macOS 14.5 launch and peer-sync verification on the signed release app.
5. Keep the gate in place after removing this blocker note.

The currently published upstream version remains
[Iroh 1.0.0](https://github.com/n0-computer/iroh-ffi/releases/tag/v1.0.0).
