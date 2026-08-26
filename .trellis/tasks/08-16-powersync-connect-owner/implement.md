# Single PowerSync connection owner implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/PowerSyncConnectionOwner.swift
- Sources/PasteBuddyPowerSyncPoC/PowerSyncConnectionError.swift
- Tests/PasteBuddyPowerSyncPoCTests/PowerSyncConnectionOwnerTests.swift

## Ordered steps

1. Define the actor state machine and injected connector protocol.
2. Test duplicate, overlapping, account-change, cancellation, and disconnect sequences.
3. Add an extension capability regression at the module boundary.

## Verification

- swift test --filter PowerSyncConnectionOwnerTests

## Stop condition

Stop if the SDK requires multiple process owners or if an extension must open the PowerSync database.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
