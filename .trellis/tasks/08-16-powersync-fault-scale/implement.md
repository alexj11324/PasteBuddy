# Fault injection and scale gate implementation plan

## Allowed files

- Tests/PasteBuddyPowerSyncPoCTests/PowerSyncFaultInjectionTests.swift
- Tests/PasteBuddyPowerSyncPoCTests/PowerSyncScaleTests.swift
- Sources/PasteBuddyPowerSyncPoC/PoCFaultControls.swift
- .trellis/tasks/08-16-powersync-fault-scale/research/results.md

## Ordered steps

1. Freeze the fault matrix and implement deterministic controls only through
   the committed database, connector, repository, and attachment protocols.
2. Run local deterministic tests, then hosted macOS/iOS scenarios.
3. Write raw aggregate results and every failure to the task research artifact.

## Verification

- swift test --filter PowerSyncFaultInjectionTests
- swift test --filter PowerSyncScaleTests
- test -f .trellis/tasks/08-16-powersync-fault-scale/research/results.md

## Stop condition

Any nonzero omission/duplicate, corruption, deadlock, unrecoverable SQLITE_BUSY, or sensitive request blocks final review.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
