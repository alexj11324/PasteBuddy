#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-${PASTEBUDDY_RELEASE_TAG:-}}"
EXPECTED_TEAM_ID="72UN4PF4BL"

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

for command in git xcrun codesign spctl shasum ditto python3; do
  require_command "$command"
done

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
  || die "Release tag must use v<semver>; received '$TAG'."

cd "$ROOT_DIR"
SOURCE_SHA="$(git rev-parse HEAD)"
TAG_SHA="$(git rev-parse "$TAG^{commit}" 2>/dev/null || true)"
[[ "$TAG_SHA" == "$SOURCE_SHA" ]] || die "Tag '$TAG' does not point to current HEAD $SOURCE_SHA."
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] \
  || die "macOS release requires a clean committed worktree."
git show-ref --verify --quiet refs/remotes/origin/main \
  || die "origin/main is unavailable; fetch the protected main branch before release."
git merge-base --is-ancestor "$SOURCE_SHA" refs/remotes/origin/main \
  || die "Release commit $SOURCE_SHA is not contained in origin/main."

: "${PASTEBUDDY_CODESIGN_KEYCHAIN:?Set PASTEBUDDY_CODESIGN_KEYCHAIN to the temporary release keychain.}"
: "${PASTEBUDDY_PROVISIONING_PROFILE:?Set PASTEBUDDY_PROVISIONING_PROFILE to the Developer ID provisioning profile.}"
: "${ASC_API_KEY_PATH:?Set ASC_API_KEY_PATH to the temporary App Store Connect key.}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID.}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID.}"

VERSION="${TAG#v}"
BUILD_NUMBER="$(git rev-list --count HEAD)"
STAGE_ROOT="$(mktemp -d "${RUNNER_TEMP:-/private/tmp}/pastebuddy-macos-release.XXXXXX")"
FINAL_OUTPUT_DIR="${PASTEBUDDY_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist/macos-$TAG}"
WORK_OUTPUT_DIR="$STAGE_ROOT/output"
NOTARY_SUBMISSION="$STAGE_ROOT/PasteBuddy-$VERSION-notary.zip"
NOTARY_RESULT="$STAGE_ROOT/notary-result.json"
NOTARY_LOG="$WORK_OUTPUT_DIR/notary-log.json"
APP_BUNDLE="$STAGE_ROOT/PasteBuddy.app"

cleanup() {
  rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT INT TERM HUP

[[ ! -e "$FINAL_OUTPUT_DIR" ]] \
  || die "Release output already exists: $FINAL_OUTPUT_DIR"
mkdir -p "$WORK_OUTPUT_DIR"

PASTEBUDDY_SIGNING_CHANNEL=release \
PASTEBUDDY_VERSION="$VERSION" \
PASTEBUDDY_BUILD_NUMBER="$BUILD_NUMBER" \
PASTEBUDDY_STAGE_ROOT="$STAGE_ROOT" \
PASTEBUDDY_DIST_DIR="$STAGE_ROOT/package" \
script/build_and_run.sh --package

[[ -d "$APP_BUNDLE" ]] || die "Signed app bundle was not produced: $APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
/usr/bin/codesign -dvvv -r- "$APP_BUNDLE" 2>&1 | /usr/bin/grep -q "TeamIdentifier=$EXPECTED_TEAM_ID" \
  || die "Developer ID artifact does not carry expected Team ID '$EXPECTED_TEAM_ID'."

/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$NOTARY_SUBMISSION"
xcrun notarytool submit "$NOTARY_SUBMISSION" \
  --key "$ASC_API_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait \
  --output-format json > "$NOTARY_RESULT"

NOTARY_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$NOTARY_RESULT")"
NOTARY_SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$NOTARY_RESULT")"
[[ "$NOTARY_STATUS" == "Accepted" ]] \
  || die "Apple notarization did not accept submission $NOTARY_SUBMISSION_ID (status=$NOTARY_STATUS)."

xcrun notarytool log "$NOTARY_SUBMISSION_ID" \
  --key "$ASC_API_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  "$NOTARY_LOG"

xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

ZIP_NAME="PasteBuddy-$VERSION-macOS-notarized.zip"
CHECKSUM_NAME="$ZIP_NAME.sha256"
PROVENANCE_NAME="PasteBuddy-$VERSION-provenance.json"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$WORK_OUTPUT_DIR/$ZIP_NAME"
(
  cd "$WORK_OUTPUT_DIR"
  /usr/bin/shasum -a 256 "$ZIP_NAME" > "$CHECKSUM_NAME"
)

cat > "$WORK_OUTPUT_DIR/$PROVENANCE_NAME" <<JSON
{
  "product": "PasteBuddy",
  "version": "$VERSION",
  "source_sha": "$SOURCE_SHA",
  "source_tag": "$TAG",
  "signing_channel": "developer-id",
  "team_id": "$EXPECTED_TEAM_ID",
  "notary_submission_id": "$NOTARY_SUBMISSION_ID",
  "notary_status": "$NOTARY_STATUS",
  "stapler_validation": "accepted",
  "gatekeeper_assessment": "accepted"
}
JSON

mkdir -p "$(dirname "$FINAL_OUTPUT_DIR")"
/usr/bin/ditto "$WORK_OUTPUT_DIR" "$FINAL_OUTPUT_DIR"
echo "macOS release artifacts: $FINAL_OUTPUT_DIR"
