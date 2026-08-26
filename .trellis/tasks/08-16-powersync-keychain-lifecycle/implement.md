# Keychain database key lifecycle implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/PowerSyncDatabaseKeyStore.swift
- Sources/PasteBuddyPowerSyncPoC/PowerSyncDatabaseKeyStoreError.swift
- Tests/PasteBuddyPowerSyncPoCTests/PowerSyncDatabaseKeyStoreTests.swift

## Ordered steps

1. Define a small key-store protocol and Security-framework implementation.
2. Make create and load separate operations.
3. Inject a fake key store for lifecycle tests and retain one real Keychain integration probe.

## Verification

- swift test --filter PowerSyncDatabaseKeyStoreTests
- swift test --filter EncryptedPowerSyncDatabaseTests

## Stop condition

Stop if stable signed-app Keychain access cannot be proved or if an existing database can trigger implicit key regeneration.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
