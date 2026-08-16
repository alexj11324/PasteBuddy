# Hosted iOS sync path

## Goal

Run the same account flow in a real iOS Simulator using the committed PoC adapters and hosted Dev services.

## Dependencies

powersync-hosted-macos.

## Requirements

- Use the real PasteBuddyiOS Simulator target or a dedicated PoC target that links the same adapter code.
- Do not grant extensions database/connect access; extension input must use the handoff path.
- Record local/offline, reconnect, download from macOS, upload to macOS, and relaunch evidence.

## Acceptance criteria

- [ ] iOS and macOS converge on the same eligible items with omission=0 and duplicate=0 in the basic path.
- [ ] Simulator relaunch preserves local state and account isolation.
- [ ] Runtime evidence identifies simulator, app build/source, account, hosted project, and redacted traffic.

## Out of scope

- No physical-device or TestFlight claim.
- No direct extension database connection.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
