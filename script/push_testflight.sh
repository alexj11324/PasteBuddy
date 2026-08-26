#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REMOTE="${PASTEBUDDY_TESTFLIGHT_REMOTE:-origin}"
BRANCH="${PASTEBUDDY_TESTFLIGHT_BRANCH:-main}"
WORKFLOW="${PASTEBUDDY_TESTFLIGHT_WORKFLOW:-testflight.yml}"
PROJECT="${PASTEBUDDY_IOS_PROJECT:-PasteBuddyiOS.xcodeproj}"
SCHEME="${PASTEBUDDY_IOS_SCHEME:-PasteBuddyiOS}"
CONFIGURATION="${PASTEBUDDY_IOS_VERIFY_CONFIGURATION:-Debug}"
DESTINATION="${PASTEBUDDY_IOS_VERIFY_DESTINATION:-generic/platform=iOS Simulator}"
DERIVED_DATA_PATH="${PASTEBUDDY_IOS_VERIFY_DERIVED_DATA:-/tmp/PasteBuddy-iOS-LocalVerify}"
MODULE_CACHE_PATH="${PASTEBUDDY_SWIFT_MODULE_CACHE:-/tmp/PasteBuddy-SwiftModuleCache}"
TIMEOUT_MINUTES="${PASTEBUDDY_TESTFLIGHT_TIMEOUT_MINUTES:-75}"

ALLOW_DIRTY=0
SKIP_SWIFT_TEST=0
SKIP_IOS_BUILD=0
SKIP_PUSH=0
NO_WAIT=0

usage() {
  cat <<USAGE
Usage: script/push_testflight.sh [options]

Runs local verification, pushes the current main HEAD, manually dispatches the
GitHub Actions TestFlight upload workflow, and waits for the upload that
submits the build to App Store Connect.

Options:
  --allow-dirty       Allow unrelated uncommitted files to remain in the worktree.
  --skip-swift-test   Skip swift test.
  --skip-ios-build    Skip the local iOS simulator compile.
  --skip-push         Do not push; useful for validating the script locally.
  --no-wait           Do not wait for the GitHub Actions upload workflow.
  -h, --help          Show this help.

Environment overrides:
  PASTEBUDDY_TESTFLIGHT_REMOTE=$REMOTE
  PASTEBUDDY_TESTFLIGHT_BRANCH=$BRANCH
  PASTEBUDDY_TESTFLIGHT_WORKFLOW=$WORKFLOW
  PASTEBUDDY_IOS_VERIFY_DESTINATION="$DESTINATION"
  PASTEBUDDY_SWIFT_MODULE_CACHE="$MODULE_CACHE_PATH"
  PASTEBUDDY_TESTFLIGHT_VERIFY_ROOT=/tmp
  PASTEBUDDY_TESTFLIGHT_TIMEOUT_MINUTES=$TIMEOUT_MINUTES
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-dirty)
      ALLOW_DIRTY=1
      ;;
    --skip-swift-test)
      SKIP_SWIFT_TEST=1
      ;;
    --skip-ios-build)
      SKIP_IOS_BUILD=1
      ;;
    --skip-push)
      SKIP_PUSH=1
      ;;
    --no-wait)
      NO_WAIT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
  shift
done

require_command git
[[ "$SKIP_SWIFT_TEST" -eq 1 ]] || require_command swift
[[ "$SKIP_IOS_BUILD" -eq 1 ]] || require_command xcodebuild
if [[ "$NO_WAIT" -eq 0 && "$SKIP_PUSH" -eq 0 ]]; then
  require_command gh
fi

head_sha="$(git rev-parse HEAD)"

mkdir -p "$MODULE_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE_PATH"

current_branch="$(git branch --show-current)"
[[ "$current_branch" == "$BRANCH" ]] || die "Run from '$BRANCH'; current branch is '$current_branch'."

dirty_status="$(git status --porcelain)"
VERIFY_DIR="$ROOT_DIR"
VERIFY_PARENT=""
REMOVE_VERIFY_WORKTREE=0

cleanup() {
  if [[ "$REMOVE_VERIFY_WORKTREE" -eq 1 ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$VERIFY_DIR" >/dev/null 2>&1 || true
    [[ -z "$VERIFY_PARENT" ]] || rmdir "$VERIFY_PARENT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -n "$dirty_status" ]]; then
  if [[ "$ALLOW_DIRTY" -ne 1 ]]; then
    echo "$dirty_status" >&2
    die "Worktree has uncommitted changes. Commit/stash them, or pass --allow-dirty only for unrelated local edits."
  fi
  echo "warning: continuing with uncommitted files that will not be pushed:" >&2
  echo "$dirty_status" >&2
  VERIFY_PARENT="$(mktemp -d "${PASTEBUDDY_TESTFLIGHT_VERIFY_ROOT:-/tmp}/pastebuddy-testflight.XXXXXX")"
  VERIFY_DIR="$VERIFY_PARENT/repo"
  git worktree add --detach "$VERIFY_DIR" "$head_sha" >/dev/null
  REMOVE_VERIFY_WORKTREE=1
  echo "warning: local verification will run against committed HEAD in $VERIFY_DIR" >&2
fi

if [[ "$SKIP_SWIFT_TEST" -eq 0 ]]; then
  log "Running Swift tests"
  (cd "$VERIFY_DIR" && swift test)
else
  log "Skipping Swift tests"
fi

if [[ "$SKIP_IOS_BUILD" -eq 0 ]]; then
  log "Compiling iOS app locally"
  (cd "$VERIFY_DIR" && xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    build)
else
  log "Skipping iOS local compile"
fi

if [[ "$SKIP_PUSH" -eq 1 ]]; then
  log "Skipping push for $head_sha"
  exit 0
fi

log "Checking remote state"
git fetch "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" --tags

if git rev-parse --verify "$REMOTE/$BRANCH" >/dev/null 2>&1; then
  read -r behind ahead < <(git rev-list --left-right --count "$REMOTE/$BRANCH"...HEAD)
  [[ "$behind" -eq 0 ]] || die "Local $BRANCH is behind $REMOTE/$BRANCH by $behind commit(s). Rebase or merge before releasing."
else
  ahead=1
fi

if [[ "${ahead:-0}" -gt 0 ]]; then
  log "Pushing $head_sha to $REMOTE/$BRANCH"
  git push "$REMOTE" "HEAD:$BRANCH"
else
  log "No unpushed commits; reusing $head_sha"
fi

log "Dispatching TestFlight workflow for $head_sha"
gh workflow run "$WORKFLOW" --ref "$BRANCH" \
  -f commit_sha="$head_sha" \
  -f confirmation=UPLOAD

if [[ "$NO_WAIT" -eq 1 ]]; then
  log "Not waiting for TestFlight upload workflow"
  exit 0
fi

deadline=$((SECONDS + TIMEOUT_MINUTES * 60))
run_id=""

log "Waiting for GitHub Actions TestFlight upload run"
while [[ -z "$run_id" && "$SECONDS" -lt "$deadline" ]]; do
  run_id="$(gh run list \
    --workflow "$WORKFLOW" \
    --branch "$BRANCH" \
    --commit "$head_sha" \
    --limit 10 \
    --json databaseId \
    --jq '.[0].databaseId // ""')"
  [[ -n "$run_id" ]] || sleep 10
done

[[ -n "$run_id" ]] || die "Timed out waiting for workflow run to appear for commit $head_sha."

run_url="$(gh run view "$run_id" --json url --jq '.url')"
echo "workflow: $run_url"

while [[ "$SECONDS" -lt "$deadline" ]]; do
  status="$(gh run view "$run_id" --json status --jq '.status')"
  conclusion="$(gh run view "$run_id" --json conclusion --jq '.conclusion // ""')"

  case "$status" in
    completed)
      if [[ "$conclusion" == "success" ]]; then
        log "TestFlight upload workflow completed successfully"
        exit 0
      fi
      gh run view "$run_id" --log-failed || true
      die "TestFlight upload workflow completed with conclusion: ${conclusion:-unknown}"
      ;;
    queued|in_progress|requested|waiting|pending)
      printf 'workflow status: %s\r' "$status"
      sleep 30
      ;;
    *)
      printf 'workflow status: %s\r' "$status"
      sleep 30
      ;;
  esac
done

die "Timed out after ${TIMEOUT_MINUTES} minutes waiting for TestFlight upload workflow."
