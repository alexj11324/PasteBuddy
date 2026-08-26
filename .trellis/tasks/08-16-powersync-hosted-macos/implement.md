# Hosted macOS sync path implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/HostedMacPoCRunner.swift
- Sources/PasteBuddyPowerSyncPoC/PowerSyncHostedConnector.swift
- Sources/PasteBuddyPowerSyncHostedMacPoC/main.swift
- Tests/PasteBuddyPowerSyncPoCTests/HostedMacIntegrationTests.swift

## Ordered steps

1. Add a dedicated macOS PoC runner using committed adapters.
2. Inject Dev endpoints/tokens at runtime and exercise the fixed path.
3. Store redacted runtime artifacts under /private/tmp and link them from task notes.

## Verification

- swift test --filter HostedMacIntegrationTests
- swift run PasteBuddyPowerSyncHostedMacPoC --hosted-macos-gate

## Stop condition

Missing hosted access or any data/privacy/integrity failure leaves this child Not run/Failed and blocks iOS.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
