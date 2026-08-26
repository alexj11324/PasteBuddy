#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_TEMP_ROOT="$(mktemp -d "${RUNNER_TEMP:-/private/tmp}/pastebuddy-ci.XXXXXX")"

cleanup() {
  rm -rf "$CI_TEMP_ROOT"
}
trap cleanup EXIT INT TERM HUP

export CLANG_MODULE_CACHE_PATH="$CI_TEMP_ROOT/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$CI_TEMP_ROOT/ModuleCache"

cd "$ROOT_DIR"

echo "==> Checking localization catalog"
python3 script/localization_catalog_workflow.py check
python3 Tests/test_localization_catalog_workflow.py --quiet
bash Tests/test_copy_compiled_localizations.sh

echo "==> Running Swift tests"
swift test --scratch-path "$CI_TEMP_ROOT/swift-build"

echo "==> Compiling iOS app without signing"
xcodebuild \
  -project PasteBuddyiOS.xcodeproj \
  -scheme PasteBuddyiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$CI_TEMP_ROOT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "CI verification passed for $(git rev-parse HEAD)"
