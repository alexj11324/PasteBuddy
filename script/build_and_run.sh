#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
EXECUTABLE_NAME="PasteBuddy"
MCP_EXECUTABLE_NAME="PasteBuddyMCP"
SIGNING_CHANNEL="${PASTEBUDDY_SIGNING_CHANNEL:-development}"
case "$SIGNING_CHANNEL" in
  development)
    DEFAULT_APP_NAME="PasteBuddy Dev"
    DEFAULT_BUNDLE_ID="com.alexjiang.PasteBuddy.dev"
    ;;
  release)
    DEFAULT_APP_NAME="PasteBuddy"
    DEFAULT_BUNDLE_ID="com.alexjiang.PasteBuddy"
    ;;
  *)
    echo "Unsupported PASTEBUDDY_SIGNING_CHANNEL='$SIGNING_CHANNEL'. Use 'development' or 'release'." >&2
    exit 1
    ;;
esac
APP_NAME="${PASTEBUDDY_APP_NAME:-$DEFAULT_APP_NAME}"
BUNDLE_ID="${PASTEBUDDY_BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
MIN_SYSTEM_VERSION="14.5"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGE_ROOT="${PASTEBUDDY_STAGE_ROOT:-/private/tmp/pastebuddy-build}"
APP_BUNDLE="$STAGE_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
MCP_APP_BINARY="$APP_MACOS/$MCP_EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Support/AppIcon.icns"
APP_ICON_NAME="AppIcon.icns"
INSTALL_BUNDLE="${PASTEBUDDY_INSTALL_PATH:-/Applications/$APP_NAME.app}"
PACKAGE_ZIP="$DIST_DIR/$APP_NAME-installable.zip"
SENTRY_KEYCHAIN_SERVICE="${PASTEBUDDY_SENTRY_KEYCHAIN_SERVICE:-PasteBuddy Sentry DSN}"
SENTRY_KEYCHAIN_ACCOUNT="${PASTEBUDDY_SENTRY_KEYCHAIN_ACCOUNT:-$BUNDLE_ID}"
SENTRY_KEYCHAIN_FALLBACK_ACCOUNT="${PASTEBUDDY_SENTRY_KEYCHAIN_FALLBACK_ACCOUNT:-pastebuddy}"

die() {
  echo "$*" >&2
  exit 1
}

is_adhoc_sign_identity() {
  local identity="$1"
  local normalized
  normalized="$(printf '%s' "$identity" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    ""|"-"|"adhoc"|"ad-hoc"|"ad hoc"|"sign to run locally")
      return 0
      ;;
  esac
  return 1
}

required_identity_prefix() {
  case "$SIGNING_CHANNEL" in
    development)
      printf '%s\n' "Apple Development"
      ;;
    release)
      printf '%s\n' "Developer ID Application"
      ;;
    *)
      die "Unsupported PASTEBUDDY_SIGNING_CHANNEL='$SIGNING_CHANNEL'. Use 'development' or 'release'."
      ;;
  esac
}

resolve_code_sign_keychain() {
  local keychain
  keychain="${PASTEBUDDY_CODESIGN_KEYCHAIN:-}"
  if [[ -z "$keychain" ]]; then
    keychain="$(/usr/bin/security default-keychain -d user 2>/dev/null | tr -d '" ' || true)"
  fi
  [[ -n "$keychain" ]] || die "Could not resolve a code signing keychain. Set PASTEBUDDY_CODESIGN_KEYCHAIN to a local keychain path."
  if [[ -n "$keychain" && ! -f "$keychain" ]]; then
    die "Configured code signing keychain does not exist: $keychain"
  fi
  printf '%s\n' "$keychain"
}

CODESIGN_KEYCHAIN="$(resolve_code_sign_keychain)"

code_signing_identities() {
  /usr/bin/security find-identity -v -p codesigning "$CODESIGN_KEYCHAIN" 2>/dev/null || true
}

parse_identity_line() {
  local line="$1"
  if [[ "$line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]+)[[:space:]]+\"(.+)\"$ ]]; then
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

identity_record_for() {
  local requested="$1"
  local parsed hash label matched_record matched_count
  matched_record=""
  matched_count=0
  while IFS= read -r parsed; do
    [[ -n "$parsed" ]] || continue
    hash="${parsed%%$'\t'*}"
    label="${parsed#*$'\t'}"
    if [[ "$requested" == "$hash" ]]; then
      printf '%s\t%s\n' "$hash" "$label"
      return 0
    fi
    if [[ "$requested" == "$label" ]]; then
      matched_record="$(printf '%s\t%s\n' "$hash" "$label")"
      matched_count=$((matched_count + 1))
    fi
  done < <(code_signing_identities | while IFS= read -r line; do parse_identity_line "$line"; done)

  if [[ "$matched_count" -eq 1 ]]; then
    printf '%s' "$matched_record"
    return 0
  fi
  if [[ "$matched_count" -gt 1 ]]; then
    die "Signing identity '$requested' is ambiguous; set PASTEBUDDY_CODESIGN_IDENTITY to a certificate hash from 'security find-identity -v -p codesigning'."
  fi
  return 1
}

find_identity_with_prefix() {
  local prefix="$1"
  local parsed hash label
  while IFS= read -r parsed; do
    [[ -n "$parsed" ]] || continue
    hash="${parsed%%$'\t'*}"
    label="${parsed#*$'\t'}"
    if [[ "$label" == "$prefix"* ]]; then
      printf '%s\n' "$hash"
      return 0
    fi
  done < <(code_signing_identities | while IFS= read -r line; do parse_identity_line "$line"; done)
  return 1
}

validate_identity_matches_channel() {
  local identity="$1"
  local label="$2"
  local required_prefix="$3"

  if is_adhoc_sign_identity "$identity"; then
    die "PasteBuddy refuses ad-hoc signing. Use Apple Development for daily builds or Developer ID Application for release/install verification."
  fi

  if [[ "$label" != "$required_prefix"* ]]; then
    die "Signing identity '$identity' is not valid for PASTEBUDDY_SIGNING_CHANNEL='$SIGNING_CHANNEL'. Expected identity prefix: '$required_prefix'."
  fi
}

resolve_code_sign_identity() {
  local required_prefix requested record identity label
  required_prefix="$(required_identity_prefix)"

  if [[ -n "${PASTEBUDDY_CODESIGN_IDENTITY:-}" ]]; then
    requested="$PASTEBUDDY_CODESIGN_IDENTITY"
    if is_adhoc_sign_identity "$requested"; then
      die "PasteBuddy refuses ad-hoc signing. Use Apple Development for daily builds or Developer ID Application for release/install verification."
    fi
    record="$(identity_record_for "$requested" || true)"
    [[ -n "$record" ]] || die "Could not find requested signing identity '$requested' in the keychain."
    identity="${record%%$'\t'*}"
    label="${record#*$'\t'}"
    validate_identity_matches_channel "$requested" "$label" "$required_prefix"
    printf '%s\n' "$identity"
    return
  fi

  identity="$(find_identity_with_prefix "$required_prefix" || true)"
  [[ -n "$identity" ]] || die "No '$required_prefix' code signing identity found. PasteBuddy will not build with ad-hoc signing."
  printf '%s\n' "$identity"
}

resolve_sentry_dsn() {
  local configured account dsn
  configured="${PASTEBUDDY_SENTRY_DSN:-${SENTRY_DSN:-}}"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return
  fi

  for account in "$SENTRY_KEYCHAIN_ACCOUNT" "$SENTRY_KEYCHAIN_FALLBACK_ACCOUNT"; do
    [[ -n "$account" ]] || continue
    dsn="$(/usr/bin/security find-generic-password -w -s "$SENTRY_KEYCHAIN_SERVICE" -a "$account" 2>/dev/null || true)"
    if [[ -n "$dsn" ]]; then
      printf '%s\n' "$dsn"
      return
    fi
  done
}

CODESIGN_IDENTITY="$(resolve_code_sign_identity)"

kill_binary() {
  local binary="$1"
  local pids=()
  local pid
  if [[ -x "$binary" ]]; then
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      pids+=("$pid")
    done < <(pgrep -f "$binary" 2>/dev/null || true)
  fi
  [[ ${#pids[@]} -gt 0 ]] || return 0
  kill "${pids[@]}" >/dev/null 2>&1 || true
  for _ in {1..50}; do
    local remaining=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        remaining=1
        break
      fi
    done
    [[ "$remaining" -eq 0 ]] && return 0
    sleep 0.1
  done
  kill -9 "${pids[@]}" >/dev/null 2>&1 || true
}

kill_existing_app() {
  kill_binary "$APP_BINARY"
  kill_binary "$INSTALL_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
  kill_binary "$STAGE_ROOT/PasteBuddy.app/Contents/MacOS/$EXECUTABLE_NAME"
  kill_binary "$STAGE_ROOT/PasteBuddy Dev.app/Contents/MacOS/$EXECUTABLE_NAME"
}

kill_existing_app

swift build
BUILD_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$EXECUTABLE_NAME"
MCP_BUILD_BINARY="$BUILD_DIR/$MCP_EXECUTABLE_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/usr/bin/ditto --norsrc --noextattr "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
/usr/bin/ditto --norsrc --noextattr "$MCP_BUILD_BINARY" "$MCP_APP_BINARY"
chmod +x "$MCP_APP_BINARY"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  /usr/bin/ditto --norsrc --noextattr "$RESOURCE_BUNDLE" "$APP_RESOURCES/$(basename "$RESOURCE_BUNDLE")"
  for localization_dir in "$RESOURCE_BUNDLE"/*.lproj; do
    [[ -d "$localization_dir" ]] || continue
    /usr/bin/ditto --norsrc --noextattr "$localization_dir" "$APP_RESOURCES/$(basename "$localization_dir")"
  done
fi
if [[ -f "$APP_ICON_SOURCE" ]]; then
  /usr/bin/ditto --norsrc --noextattr "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>PasteBuddySigningChannel</key>
  <string>$SIGNING_CHANNEL</string>
  <key>PasteBuddyCodeSigningIdentity</key>
  <string>$CODESIGN_IDENTITY</string>
  <key>PasteBuddyStableAppPath</key>
  <string>$INSTALL_BUNDLE</string>
</dict>
</plist>
PLIST

if [[ "$SIGNING_CHANNEL" == "development" && "$BUNDLE_ID" == "com.alexjiang.PasteBuddy.dev" ]]; then
  /usr/bin/plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"com.alexjiang.PasteBuddy.dev.panel","CFBundleURLSchemes":["pastebuddy-dev"]}]' "$INFO_PLIST"
fi

CONFIGURED_SENTRY_DSN="$(resolve_sentry_dsn)"
CONFIGURED_SENTRY_ENVIRONMENT="${PASTEBUDDY_SENTRY_ENVIRONMENT:-}"
if [[ -n "$CONFIGURED_SENTRY_DSN" ]]; then
  /usr/bin/plutil -insert PasteBuddySentryDSN -string "$CONFIGURED_SENTRY_DSN" "$INFO_PLIST"
fi
if [[ -n "$CONFIGURED_SENTRY_ENVIRONMENT" ]]; then
  /usr/bin/plutil -insert PasteBuddySentryEnvironment -string "$CONFIGURED_SENTRY_ENVIRONMENT" "$INFO_PLIST"
fi

assert_safe_bundle_path() {
  local bundle="$1"
  [[ -n "$bundle" ]] || die "Refusing to operate on an empty app bundle path."
  [[ "$bundle" == *.app ]] || die "Refusing to operate on non-.app path: $bundle"
  [[ "$bundle" != "/" ]] || die "Refusing to operate on root path."
}

verify_code_signature() {
  local bundle="$1"
  local details

  /usr/bin/codesign --verify --deep --strict --verbose=4 "$bundle" >/dev/null
  details="$(/usr/bin/codesign -dvvv "$bundle" 2>&1)"

  if [[ "$details" == *"Signature=adhoc"* ]]; then
    die "Refusing ad-hoc signed app bundle: $bundle"
  fi
  if [[ "$details" == *"Authority=(unavailable)"* ]]; then
    die "Code signature authority is unavailable for $bundle. Re-sign from a normal macOS session with a trusted certificate chain."
  fi
  if [[ "$details" == *"TeamIdentifier=not set"* ]]; then
    die "Code signature has no TeamIdentifier for $bundle."
  fi
  if [[ "$details" != *"Identifier=$BUNDLE_ID"* ]]; then
    printf '%s\n' "$details" >&2
    die "Signed bundle identifier does not match expected '$BUNDLE_ID'."
  fi
  if [[ "$SIGNING_CHANNEL" == "release" ]]; then
    /usr/sbin/spctl --assess --type execute --verbose=4 "$bundle" >/dev/null
  fi
}

sign_app() {
  local bundle="$1"
  assert_safe_bundle_path "$bundle"
  local codesign_args=(--force --deep --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID")
  if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
    codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  /usr/bin/codesign "${codesign_args[@]}" "$bundle"
  verify_code_signature "$bundle"
}

codesign_binary() {
  local binary="$1"
  local codesign_args=(--force --sign "$CODESIGN_IDENTITY")
  if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
    codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  /usr/bin/codesign "${codesign_args[@]}" "$binary"
  /usr/bin/codesign --verify --strict --verbose=4 "$binary"
}

codesign_binary "$MCP_APP_BINARY"
sign_app "$APP_BUNDLE"

package_app() {
  local source_bundle="${1:-$APP_BUNDLE}"
  rm -f "$PACKAGE_ZIP"
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$source_bundle" "$PACKAGE_ZIP"
  printf 'Packaged %s\n' "$PACKAGE_ZIP"
}

install_app() {
  kill_existing_app
  assert_safe_bundle_path "$INSTALL_BUNDLE"
  rm -rf "$INSTALL_BUNDLE"
  /usr/bin/ditto --norsrc --noextattr "$APP_BUNDLE" "$INSTALL_BUNDLE"
  sign_app "$INSTALL_BUNDLE"
  /usr/bin/codesign --verify --strict --verbose=4 "$INSTALL_BUNDLE/Contents/MacOS/$MCP_EXECUTABLE_NAME"
  printf 'Installed %s signed with %s (%s, %s)\n' "$INSTALL_BUNDLE" "$CODESIGN_IDENTITY" "$SIGNING_CHANNEL" "$BUNDLE_ID"
}

open_app() {
  /usr/bin/open -n "$INSTALL_BUNDLE"
}

print_runtime_diagnostics() {
  local binary="$INSTALL_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
  [[ -x "$binary" ]] || die "Runtime diagnostics binary is missing: $binary"
  printf 'Runtime diagnostics for %s:\n' "$INSTALL_BUNDLE"
  "$binary" --print-runtime-diagnostics
}

case "$MODE" in
  run)
    install_app
    print_runtime_diagnostics
    open_app
    ;;
  --debug|debug)
    install_app
    print_runtime_diagnostics
    lldb -- "$INSTALL_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
    ;;
  --logs|logs)
    install_app
    print_runtime_diagnostics
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    install_app
    print_runtime_diagnostics
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    install_app
    print_runtime_diagnostics
    /usr/bin/open -n -W "$INSTALL_BUNDLE" &
    OPEN_PID="$!"
    for _ in {1..20}; do
      if pgrep -x "$EXECUTABLE_NAME" >/dev/null || pgrep -f "$INSTALL_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null; then
        kill "$OPEN_PID" >/dev/null 2>&1 || true
        exit 0
      fi
      if ! kill -0 "$OPEN_PID" >/dev/null 2>&1; then
        echo "$APP_NAME exited before verify could observe a running process" >&2
        exit 1
      fi
      sleep 0.5
    done
    kill "$OPEN_PID" >/dev/null 2>&1 || true
    echo "$EXECUTABLE_NAME did not appear in the process table after launch" >&2
    exit 1
    ;;
  --install|install)
    install_app
    ;;
  --package|package)
    package_app
    ;;
  --install-package|install-package)
    install_app
    package_app "$INSTALL_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install|--package|--install-package]" >&2
    exit 2
    ;;
esac
