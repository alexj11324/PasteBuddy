#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <swiftpm|macos|ios> <bundle-path>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage

platform="$1"
bundle="$2"

verify_manifest() {
  local manifest="$1"
  local user_defaults_reason="$2"
  [[ -f "$manifest" ]] || {
    echo "missing app privacy manifest: $manifest" >&2
    exit 1
  }

  /usr/bin/python3 - "$manifest" "$user_defaults_reason" <<'PY'
import plistlib
import sys

path, user_defaults_reason = sys.argv[1:]
with open(path, "rb") as source:
    actual = plistlib.load(source)

expected = {
    "NSPrivacyAccessedAPITypes": [{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": [user_defaults_reason],
    }],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
}
if actual != expected:
    raise SystemExit(f"unexpected app privacy manifest at {path}: {actual!r}")
PY
}

verify_exported_type() {
  local info_plist="$1"
  local identifier="$2"
  [[ -f "$info_plist" ]] || {
    echo "missing Info.plist: $info_plist" >&2
    exit 1
  }

  /usr/bin/python3 - "$info_plist" "$identifier" <<'PY'
import plistlib
import sys

path, identifier = sys.argv[1:]
with open(path, "rb") as source:
    info = plistlib.load(source)

matches = [
    declaration
    for declaration in info.get("UTExportedTypeDeclarations", [])
    if declaration.get("UTTypeIdentifier") == identifier
]
if len(matches) != 1:
    raise SystemExit(f"expected one exported declaration for {identifier} in {path}")

declaration = matches[0]
if not declaration.get("UTTypeDescription"):
    raise SystemExit(f"missing description for {identifier} in {path}")
if "public.data" not in declaration.get("UTTypeConformsTo", []):
    raise SystemExit(f"{identifier} must conform to public.data in {path}")
PY
}

case "$platform" in
  swiftpm)
    verify_manifest "$bundle/PrivacyInfo.xcprivacy" "CA92.1"
    ;;
  macos)
    verify_manifest "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" "CA92.1"
    verify_exported_type "$bundle/Contents/Info.plist" "app.pastebuddy.pinboard-item-ids"
    ;;
  ios)
    verify_manifest "$bundle/PrivacyInfo.xcprivacy" "1C8F.1"
    verify_manifest "$bundle/PlugIns/PasteBuddyKeyboard.appex/PrivacyInfo.xcprivacy" "1C8F.1"
    verify_manifest "$bundle/PlugIns/PasteBuddyShareExtension.appex/PrivacyInfo.xcprivacy" "1C8F.1"
    verify_manifest "$bundle/PlugIns/PasteBuddyActionExtension.appex/PrivacyInfo.xcprivacy" "1C8F.1"
    verify_exported_type "$bundle/Info.plist" "app.pastebuddy.mobile-pinboard-item-ids"
    ;;
  *)
    usage
    ;;
esac

echo "app privacy artifacts verified for $platform: $bundle"
