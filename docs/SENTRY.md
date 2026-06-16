# Sentry Deployment

PasteBuddy integrates the Sentry Cocoa SDK for crash and error reporting in the
macOS app target. The integration is disabled by default and starts only when a
deployment provides a DSN.

## Runtime Configuration

Do not commit the DSN or auth tokens to source control. Inject the DSN from the
deployment environment:

```bash
PASTEBUDDY_SENTRY_DSN="https://public-dsn@example.ingest.sentry.io/project-id" \
PASTEBUDDY_SENTRY_ENVIRONMENT="production" \
./script/build_and_run.sh --package
```

For local development, the build script can also read the DSN from macOS
Keychain. Store it as a generic password with service `PasteBuddy Sentry DSN`
and account `pastebuddy`; environment variables still take precedence.

The build script writes `PasteBuddySentryDSN` and, when provided,
`PasteBuddySentryEnvironment` into the generated app bundle `Info.plist`.
Runtime also accepts `PASTEBUDDY_SENTRY_DSN` or `SENTRY_DSN` from the process
environment for non-LaunchServices runs.

Environment defaults:

- `development` for development-signed builds.
- `production` for release-signed builds.
- `PASTEBUDDY_SENTRY_ENVIRONMENT` overrides both.

## Privacy Boundary

The app starts Sentry with default PII disabled. It also disables automatic
network breadcrumbs, network tracking, automatic breadcrumb tracking, automatic
session tracking, extra stack traces for non-crash events, and performance
tracing.

Do not add manual Sentry events that include clipboard payloads, OCR text, URLs,
file contents, image bytes, search query text, keys, tokens, or user secrets.

## Verification

Run the standard app verification path:

```bash
./script/build_and_run.sh --verify
```

The runtime diagnostics print only:

- `sentryConfigured=true|false`
- `sentryEnvironment=<environment-or-not-configured>`

They never print the DSN.
