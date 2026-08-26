# Encrypted database open fail closed implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/EncryptedPowerSyncDatabase.swift
- Sources/PasteBuddyPowerSyncPoC/EncryptedPowerSyncDatabaseError.swift
- Tests/PasteBuddyPowerSyncPoCTests/EncryptedPowerSyncDatabaseTests.swift

## Ordered steps

1. Define the typed open result and error taxonomy.
2. Implement new-file versus existing-file open as separate explicit branches.
3. Add real encrypted file round-trip and preservation tests.

## Verification

- swift test --filter EncryptedPowerSyncDatabaseTests
- git diff --check

## Stop condition

Stop if the SDK encryption hooks cannot distinguish existing-file key failure from first creation or if a failure mutates the file.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
