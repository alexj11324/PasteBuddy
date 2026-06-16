#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PasteBuddy"
BUNDLE_ID="com.pastebuddy.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGE_ROOT="${PASTEBUDDY_STAGE_ROOT:-/private/tmp/pastebuddy-build}"
APP_BUNDLE="$STAGE_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Support/AppIcon.icns"
APP_ICON_NAME="AppIcon.icns"
INSTALL_BUNDLE="${PASTEBUDDY_INSTALL_PATH:-/Applications/$APP_NAME.app}"
PACKAGE_ZIP="$DIST_DIR/$APP_NAME-installable.zip"
SIGNING_CHANNEL="${PASTEBUDDY_SIGNING_CHANNEL:-development}"

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

code_signing_identities() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null || true
}

parse_identity_line() {
  local line="$1"
  if [[ "$line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]+)[[:space:]]+\"(.+)\"$ ]]; then
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

identity_label_for() {
  local requested="$1"
  local parsed hash label
  while IFS= read -r parsed; do
    [[ -n "$parsed" ]] || continue
    hash="${parsed%%$'\t'*}"
    label="${parsed#*$'\t'}"
    if [[ "$requested" == "$hash" || "$requested" == "$label" ]]; then
      printf '%s\n' "$label"
      return 0
    fi
  done < <(code_signing_identities | while IFS= read -r line; do parse_identity_line "$line"; done)
  return 1
}

find_identity_with_prefix() {
  local prefix="$1"
  local parsed label
  while IFS= read -r parsed; do
    [[ -n "$parsed" ]] || continue
    label="${parsed#*$'\t'}"
    if [[ "$label" == "$prefix"* ]]; then
      printf '%s\n' "$label"
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
  local required_prefix requested label
  required_prefix="$(required_identity_prefix)"

  if [[ -n "${PASTEBUDDY_CODESIGN_IDENTITY:-}" ]]; then
    requested="$PASTEBUDDY_CODESIGN_IDENTITY"
    if is_adhoc_sign_identity "$requested"; then
      die "PasteBuddy refuses ad-hoc signing. Use Apple Development for daily builds or Developer ID Application for release/install verification."
    fi
    label="$(identity_label_for "$requested" || true)"
    [[ -n "$label" ]] || die "Could not find requested signing identity '$requested' in the keychain."
    validate_identity_matches_channel "$requested" "$label" "$required_prefix"
    printf '%s\n' "$requested"
    return
  fi

  label="$(find_identity_with_prefix "$required_prefix" || true)"
  [[ -n "$label" ]] || die "No '$required_prefix' code signing identity found. PasteBuddy will not build with ad-hoc signing."
  printf '%s\n' "$label"
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
  kill_binary "$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME"
}

kill_existing_app

swift build
BUILD_DIR="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/usr/bin/ditto --norsrc --noextattr "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
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
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_app() {
  local bundle="$1"
  /usr/bin/codesign --force --deep --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$bundle"
}

sign_app "$APP_BUNDLE"

package_app() {
  local source_bundle="${1:-$APP_BUNDLE}"
  rm -f "$PACKAGE_ZIP"
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$source_bundle" "$PACKAGE_ZIP"
  printf 'Packaged %s\n' "$PACKAGE_ZIP"
}

install_app() {
  kill_existing_app
  rm -rf "$INSTALL_BUNDLE"
  /usr/bin/ditto --norsrc --noextattr "$APP_BUNDLE" "$INSTALL_BUNDLE"
  sign_app "$INSTALL_BUNDLE"
  printf 'Installed %s signed with %s\n' "$INSTALL_BUNDLE" "$CODESIGN_IDENTITY"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -n -W "$APP_BUNDLE" &
    OPEN_PID="$!"
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null || pgrep -f "$APP_BINARY" >/dev/null; then
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
    echo "$APP_NAME did not appear in the process table after launch" >&2
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
