# Hosted iOS sync path implementation plan

## Allowed files

- PasteBuddyiOS.xcodeproj/project.pbxproj
- PasteBuddyiOS.xcodeproj/xcshareddata/xcschemes/PasteBuddyPowerSyncPoC.xcscheme
- Sources/PasteBuddyPowerSyncPoCiOS/PasteBuddyPowerSyncPoCApp.swift
- Tests/PasteBuddyPowerSyncPoCTests/HostedIOSContractTests.swift

## Ordered steps

1. Add a dedicated iOS PoC entry point linked to the shared adapter.
2. Build and launch in a real Simulator, then operate the fixed cross-device path.
3. Capture redacted runtime and local-state evidence under /private/tmp.

## Verification

- xcodebuild -project PasteBuddyiOS.xcodeproj -scheme PasteBuddyPowerSyncPoC -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO build
- swift test --filter HostedIOSContractTests

## Stop condition

If the formal SDK cannot meet iOS Simulator, encrypted database, or single-owner requirements, record Hard Stop.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
