# PowerSync SDK linkage smoke implementation plan

## Allowed files

- Package.swift
- Package.resolved
- Sources/PasteBuddyPowerSyncPoC/PowerSyncSDKSmoke.swift
- Sources/PasteBuddyPowerSyncHostedMacPoC/main.swift
- Tests/PasteBuddyPowerSyncPoCTests/PowerSyncSDKSmokeTests.swift

## Ordered steps

1. Add exact package versions and freeze the library, hosted executable shell,
   and shared PoC test target graph.
2. Add one smoke symbol that imports and instantiates only public SDK types needed to prove linkage.
3. Compile macOS and the library scheme for iOS Simulator without editing the
   application project.

## Verification

- swift package resolve
- swift build --target PasteBuddyPowerSyncPoC
- swift test --filter PowerSyncSDKSmokeTests
- xcodebuild -scheme PasteBuddyPowerSyncPoC -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

## Stop condition

Stop WP1 if PowerSync, encrypted SQLite, current GRDB, and both platform graphs cannot coexist without unsupported dependency surgery.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
