# Quota pause and queue settlement implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/QuotaAndSettlementCoordinator.swift
- Tests/PasteBuddyPowerSyncPoCTests/QuotaAndSettlementTests.swift

## Ordered steps

1. Define exhaustive permanent versus retryable outcomes.
2. Persist the local rejection overlay through the committed settlement seam
   before completing the affected SDK transaction/batch; do not edit the
   repository or backfill owners.
3. Test both quotas, release/resume, mixed valid/rejected work, and crash replay.

## Verification

- swift test --filter QuotaAndSettlementTests
- git diff --check

## Stop condition

Stop if the SDK queue cannot be safely settled after permanent rejection without losing unrelated operations.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
