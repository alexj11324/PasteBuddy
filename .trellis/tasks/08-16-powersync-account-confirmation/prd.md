# Account B pre-connect confirmation

## Goal

Block PowerSync connect, backfill, and upload after login until the user explicitly accepts the computed eligible history for that account.

## Dependencies

powersync-privacy-admission and powersync-account-isolation.

## Requirements

- Compute eligible item count and attachment bytes locally using the same admission policy as upload.
- Confirmation state is account-specific and invalidated when the candidate set materially changes.
- Refusal preserves local-only history and produces no connection or upload.

## Acceptance criteria

- [ ] Before acceptance, connection attempts, synced inserts, and network recorder calls are all zero.
- [ ] The displayed count/bytes equal the exact candidate set consumed after acceptance.
- [ ] Refusal and relaunch remain local-only; later explicit acceptance starts from a fresh candidate snapshot.

## Out of scope

- No auto-accept based on prior account consent.
- No connect-before-dialog optimization.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
