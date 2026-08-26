# PowerSync SDK linkage smoke

## Goal

Pin an approved PowerSync Swift SDK and encrypted SQLite dependency set, then prove both Apple platform build graphs can link the smallest PoC target.

## Dependencies

WP0 planning commit only.

## Requirements

- Use exact dependency versions in Package.resolved; no floating branch or local checkout.
- Freeze one `PasteBuddyPowerSyncPoC` library product/target, one shared
  `PasteBuddyPowerSyncPoCTests` test target, and one minimal
  `PasteBuddyPowerSyncHostedMacPoC` executable shell. Do not integrate Store,
  UI, Auth, or hosted services.
- Record the official release/version evidence used at execution time.

## Acceptance criteria

- [ ] The library, hosted-mac executable shell, and shared PoC test target
  resolve and link PowerSync plus the approved encrypted SQLite product.
- [ ] PasteBuddyiOS Simulator build resolves the same package graph without duplicate SQLite or GRDB linker symbols.
- [ ] Package.resolved contains one reproducible version per added dependency.

## Out of scope

- No database schema, repository, network connector, Store, UI, or hosted resource changes.
- Do not use the unfinished /private/tmp PoC as a wholesale patch.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
