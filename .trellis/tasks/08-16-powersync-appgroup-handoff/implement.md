# Encrypted App Group handoff implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/EncryptedAppGroupHandoff.swift
- Tests/PasteBuddyPowerSyncPoCTests/EncryptedAppGroupHandoffTests.swift

## Ordered steps

1. Define a versioned authenticated envelope and atomic file replace.
2. Implement producer and single consumer with durable idempotency by consuming
   the committed key-store protocol; do not edit the Keychain owner.
3. Exercise tamper, partial-write, duplicate, and crash boundaries.

## Verification

- swift test --filter EncryptedAppGroupHandoffTests

## Stop condition

Stop if plaintext is persisted, authentication is optional, or extension consumption requires a database connection.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
