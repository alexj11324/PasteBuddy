#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="/Applications/PasteBuddy Dev.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s {side|shelf|toggle}\n' "${0##*/}" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
command="$1"
case "$command" in
  side|shelf|toggle) ;;
  *) usage ;;
esac

[[ -d "$APP_BUNDLE" && -f "$INFO_PLIST" ]] || die "Missing $APP_BUNDLE; run script/build_and_run.sh --verify first."

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
}

[[ "$(plist_value CFBundleIdentifier)" == "com.alexjiang.PasteBuddy.dev" ]] || die "Unexpected development bundle identifier."
[[ "$(plist_value PasteBuddySigningChannel)" == "development" ]] || die "Unexpected signing channel."
[[ "$(plist_value PasteBuddyStableAppPath)" == "$APP_BUNDLE" ]] || die "Unexpected stable app path."
[[ "$(plist_value CFBundleURLTypes:0:CFBundleURLSchemes:0)" == "pastebuddy-dev" ]] || die "Development URL scheme is not registered; rebuild the app."

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null
signature_details="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
[[ "$signature_details" == *"Authority=Apple Development:"* ]] || die "PasteBuddy Dev.app is not Apple Development signed."
[[ "$signature_details" != *"Signature=adhoc"* ]] || die "PasteBuddy Dev.app is ad-hoc signed."
[[ "$signature_details" != *"TeamIdentifier=not set"* ]] || die "PasteBuddy Dev.app has no Team ID."

url="pastebuddy-dev://panel/$command"
/usr/bin/open -g -a "$APP_BUNDLE" "$url"
