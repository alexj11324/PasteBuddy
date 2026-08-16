# Legacy GRDB read-only migration implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/LegacyGRDBImporter.swift
- Tests/PasteBuddyPowerSyncPoCTests/LegacyGRDBImporterTests.swift

## Ordered steps

1. Build a formal fixture from the current PasteBuddyDatabase schema.
2. Import through the repository owner's read-only import sink with a durable
   marker; do not edit the repository owner.
3. Compare source digest and destination logical rows across failure/retry.

## Verification

- swift test --filter LegacyGRDBImporterTests

## Stop condition

Stop if read-only source access cannot be guaranteed or any required legacy item cannot be represented without a second database.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
