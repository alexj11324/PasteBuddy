#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${PASTEBUDDY_CI_WORKFLOW:-ci.yml}"
TIMEOUT_MINUTES="${PASTEBUDDY_CI_TIMEOUT_MINUTES:-90}"
REQUESTED_REF="${1:-HEAD}"

die() {
  echo "error: $*" >&2
  exit 1
}

for command in git gh; do
  command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

cd "$ROOT_DIR"
TARGET_SHA="$(git rev-parse --verify "$REQUESTED_REF^{commit}")"
[[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve a full commit SHA from '$REQUESTED_REF'."

REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
OWNER="${REPOSITORY%%/*}"
ACTOR="$(gh api user --jq .login)"
[[ "$ACTOR" == "$OWNER" ]] || die "Only repository owner '$OWNER' may approve a workflow_dispatch re-run."
gh api "repos/$REPOSITORY/commits/$TARGET_SHA" --silent \
  || die "Commit $TARGET_SHA is not available from GitHub. Push it before approving CI."

RUN_TITLE="CI / approve $TARGET_SHA"
echo "Dispatching owner-approved CI for $TARGET_SHA"
gh workflow run "$WORKFLOW" --ref main \
  -f commit_sha="$TARGET_SHA" \
  -f confirmation=RUN

deadline=$((SECONDS + TIMEOUT_MINUTES * 60))
run_id=""
while [[ -z "$run_id" && "$SECONDS" -lt "$deadline" ]]; do
  run_id="$(gh run list \
    --workflow "$WORKFLOW" \
    --event workflow_dispatch \
    --limit 20 \
    --json databaseId,displayTitle \
    --jq ".[] | select(.displayTitle == \"$RUN_TITLE\") | .databaseId" \
    | head -n 1)"
  [[ -n "$run_id" ]] || sleep 5
done

[[ -n "$run_id" ]] || die "Timed out waiting for the local CI workflow run to appear."
gh run view "$run_id" --json url --jq '"workflow: \(.url)"'
gh run watch "$run_id" --exit-status
