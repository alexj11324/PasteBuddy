# Zero-network privacy admission implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/CloudSyncAdmissionPolicy.swift
- Tests/PasteBuddyPowerSyncPoCTests/CloudSyncAdmissionPolicyTests.swift

## Ordered steps

1. Define the exhaustive admission result and reason codes.
2. Consume the repository owner's admission seam before synced-table insertion;
   do not edit the repository owner.
3. Test every privacy/session/settings branch with a zero-call recorder.

## Verification

- swift test --filter CloudSyncAdmissionPolicyTests

## Stop condition

Any observed network-capable call for a rejected fixture is an immediate WP1 Hard Stop until the owner boundary is corrected.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
