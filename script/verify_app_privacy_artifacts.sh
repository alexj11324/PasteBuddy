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
  local profile="$2"
  [[ -f "$manifest" ]] || {
    echo "missing app privacy manifest: $manifest" >&2
    exit 1
  }

  /usr/bin/python3 - "$manifest" "$profile" <<'PY'
import plistlib
import sys

path, profile = sys.argv[1:]
with open(path, "rb") as source:
    actual = plistlib.load(source)

accessed_api_types = [{
    "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
    "NSPrivacyAccessedAPITypeReasons": ["CA92.1" if profile == "macos" else "1C8F.1"],
}]
collected_data_types = []
if profile == "macos":
    accessed_api_types.extend([{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime",
        "NSPrivacyAccessedAPITypeReasons": ["35F9.1"],
    }, {
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
        "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
    }])
    collected_data_types = [{
        "NSPrivacyCollectedDataType": data_type,
        "NSPrivacyCollectedDataTypeLinked": False,
        "NSPrivacyCollectedDataTypeTracking": False,
        "NSPrivacyCollectedDataTypePurposes": [
            "NSPrivacyCollectedDataTypePurposeAppFunctionality"
        ],
    } for data_type in [
        "NSPrivacyCollectedDataTypeCrashData",
        "NSPrivacyCollectedDataTypePerformanceData",
        "NSPrivacyCollectedDataTypeOtherDiagnosticData",
    ]]
elif profile != "ios":
    raise SystemExit(f"unexpected privacy manifest profile: {profile}")

expected = {
    "NSPrivacyAccessedAPITypes": accessed_api_types,
    "NSPrivacyCollectedDataTypes": collected_data_types,
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

verify_grdb_manifest() {
  local manifest="$1"
  [[ -f "$manifest" ]] || {
    echo "missing embedded GRDB privacy manifest: $manifest" >&2
    exit 1
  }

  /usr/bin/python3 - "$manifest" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    actual = plistlib.load(source)

expected = {
    "NSPrivacyAccessedAPITypes": [],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
}
if actual != expected:
    raise SystemExit(f"unexpected embedded GRDB privacy manifest at {sys.argv[1]}: {actual!r}")
PY
}

verify_ios_bundle() {
  local bundle_root="$1"
  verify_manifest "$bundle_root/PrivacyInfo.xcprivacy" "ios"
  verify_grdb_manifest "$bundle_root/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy"
}

report_iroh_manifest_status() {
  local framework="$1"
  [[ -d "$framework" ]] || {
    echo "missing embedded Iroh.framework: $framework" >&2
    exit 1
  }
  if [[ -f "$framework/PrivacyInfo.xcprivacy" ]]; then
    echo "Iroh.framework now contains a privacy manifest; review its declarations before accepting this new upstream artifact." >&2
    exit 1
  fi
  echo "notice: Iroh.framework has no PrivacyInfo.xcprivacy; this check does not claim Iroh required-reason API coverage." >&2
}

case "$platform" in
  swiftpm)
    verify_manifest "$bundle/PrivacyInfo.xcprivacy" "macos"
    ;;
  macos)
    verify_manifest "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" "macos"
    verify_exported_type "$bundle/Contents/Info.plist" "app.pastebuddy.pinboard-item-ids"
    ;;
  ios)
    verify_ios_bundle "$bundle"
    verify_ios_bundle "$bundle/PlugIns/PasteBuddyKeyboard.appex"
    verify_ios_bundle "$bundle/PlugIns/PasteBuddyShareExtension.appex"
    verify_ios_bundle "$bundle/PlugIns/PasteBuddyActionExtension.appex"
    report_iroh_manifest_status "$bundle/Frameworks/Iroh.framework"
    verify_exported_type "$bundle/Info.plist" "app.pastebuddy.mobile-pinboard-item-ids"
    ;;
  *)
    usage
    ;;
esac

echo "declared app and embedded dependency privacy artifacts verified for $platform: $bundle"
