# Single PowerSync connection owner

## Goal

Make the main application process the only component able to own PowerSync connect/disconnect lifecycle.

## Dependencies

powersync-sdk-linkage.

## Requirements

- An actor is the unique lifecycle owner and serializes connect, account change, reconnect, and disconnect.
- Extension-facing modules receive no database or connector capability.
- Repeated or overlapping connect requests are idempotent or visibly rejected.

## Acceptance criteria

- [ ] Concurrent connect requests produce one live connection owner.
- [ ] Account change disconnects the old session before a new connection becomes observable.
- [ ] Compile-time/runtime tests prove keyboard/share/action extension paths cannot invoke connect.

## Out of scope

- No hosted connector credentials or UI integration.
- No second singleton in macOS and iOS modules.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
