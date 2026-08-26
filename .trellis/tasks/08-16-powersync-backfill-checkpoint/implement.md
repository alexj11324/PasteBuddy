# Backfill ordering and checkpoints implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/BackfillCoordinator.swift
- Tests/PasteBuddyPowerSyncPoCTests/BackfillCoordinatorTests.swift

## Ordered steps

1. Define stable candidate ordering and account-scoped checkpoint.
2. Implement one-batch-at-a-time selection/settlement through the committed
   repository seam; do not edit the repository owner.
3. Test pause, crash, restart, concurrent capture, and idempotent replay.

## Verification

- swift test --filter BackfillCoordinatorTests
- git diff --check

## Stop condition

Stop if the SDK cannot expose a durable settlement boundary needed to prevent omission or duplicate backfill.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
