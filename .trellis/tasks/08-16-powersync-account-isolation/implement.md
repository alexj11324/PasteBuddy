# Account cache and cloud ID isolation implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/AccountCloudIdentity.swift
- Sources/PasteBuddyPowerSyncPoC/AccountCacheCoordinator.swift
- Tests/PasteBuddyPowerSyncPoCTests/AccountIsolationTests.swift

## Ordered steps

1. Define deterministic account-scoped identity encoding.
2. Consume the repository owner's account-scoped cache seam; do not edit the
   repository owner.
3. Test A/B switching, logout, relogin, and same-local-item mapping.

## Verification

- swift test --filter AccountIsolationTests
- git diff --check

## Stop condition

Any cross-account row, ID collision, or logout-triggered server/local-history deletion blocks WP1.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
