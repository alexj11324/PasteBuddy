# Single database repository boundary implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/PowerSyncPoCSchema.swift
- Sources/PasteBuddyPowerSyncPoC/PowerSyncClipboardRepository.swift
- Sources/PasteBuddyPowerSyncPoC/PowerSyncRepositoryModels.swift
- Tests/PasteBuddyPowerSyncPoCTests/PowerSyncClipboardRepositoryTests.swift

## Ordered steps

1. Freeze the PoC schema, repository DTOs, and typed downstream seams.
2. Implement local-only persistence and deterministic merged reads.
3. Add restart, deduplication, and seam-contract tests before cloud upload behavior.

## Verification

- swift test --filter PowerSyncClipboardRepositoryTests
- git diff --check

## Stop condition

Stop if formal SDK storage cannot represent all three roles in one database or if UI reads require dual authorities.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
