#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "repository contract failed: $1" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing $1"
}

require_executable() {
  [[ -x "$1" ]] || fail "$1 is not executable"
}

require_literal() {
  local file="$1"
  local literal="$2"
  /usr/bin/grep -Fq -- "$literal" "$file" || fail "$file is missing required contract: $literal"
}

reject_literal() {
  local file="$1"
  local literal="$2"
  if /usr/bin/grep -Fq -- "$literal" "$file"; then
    fail "$file contains forbidden contract: $literal"
  fi
}

require_file script/build_and_run.sh
require_executable script/open_dev_panel.sh
require_file script/push_testflight.sh
require_file .github/workflows/testflight.yml

require_literal script/build_and_run.sh 'PASTEBUDDY_CODESIGN_KEYCHAIN'
require_literal script/build_and_run.sh 'security default-keychain -d user'
require_literal script/build_and_run.sh 'security find-identity -v -p codesigning "$CODESIGN_KEYCHAIN"'
require_literal script/build_and_run.sh 'codesign_args+=(--keychain "$CODESIGN_KEYCHAIN")'
reject_literal script/build_and_run.sh 'security find-identity -v -p codesigning 2>/dev/null'
reject_literal script/build_and_run.sh 'unlock-keychain'
reject_literal script/build_and_run.sh 'set-key-partition-list'

require_literal script/build_and_run.sh '"$SIGNING_CHANNEL" == "development"'
require_literal script/build_and_run.sh '"$BUNDLE_ID" == "com.alexjiang.PasteBuddy.dev"'
require_literal script/build_and_run.sh 'CFBundleURLTypes'
require_literal script/build_and_run.sh 'pastebuddy-dev'
require_literal script/build_and_run.sh '<key>LSUIElement</key>'
require_literal script/build_and_run.sh 'PASTEBUDDY_DISABLE_CLIPBOARD_MONITOR_FOR_VERIFICATION'
require_literal script/build_and_run.sh 'PasteBuddyDisableClipboardMonitoringForDevelopmentVerification'
require_literal script/build_and_run.sh 'Clipboard monitor verification override is only supported for development signing.'
require_literal script/build_and_run.sh 'PASTEBUDDY_DISABLE_CLIPBOARD_MONITOR_FOR_VERIFICATION must be 0 or 1.'

require_literal script/open_dev_panel.sh 'APP_BUNDLE="/Applications/PasteBuddy Dev.app"'
require_literal script/open_dev_panel.sh 'codesign --verify --deep --strict'
require_literal script/open_dev_panel.sh 'Authority=Apple Development:'
require_literal script/open_dev_panel.sh '/usr/bin/open -g -a "$APP_BUNDLE" "$url"'
reject_literal script/open_dev_panel.sh 'osascript'

require_literal script/push_testflight.sh 'git fetch "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" --tags'
reject_literal script/push_testflight.sh 'git fetch "$REMOTE" "$BRANCH" --tags'

require_literal .github/workflows/testflight.yml 'script/verify_repository_contracts.sh'
require_literal .github/workflows/testflight.yml 'python3 script/localization_catalog_workflow.py check'

echo "repository contracts verified"
