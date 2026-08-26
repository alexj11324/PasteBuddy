# Account B pre-connect confirmation implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/AccountBackfillConsentGate.swift
- Tests/PasteBuddyPowerSyncPoCTests/AccountBackfillConsentGateTests.swift

## Ordered steps

1. Define account-scoped candidate snapshot and consent record.
2. Compose the committed admission and connection protocols behind the consent
   barrier; do not edit either owner.
3. Test accept, reject, candidate change, account change, and relaunch.

## Verification

- swift test --filter AccountBackfillConsentGateTests
- git diff --check

## Stop condition

Any pre-consent connection or upload is a privacy Gate failure and stops subsequent hosted work.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
