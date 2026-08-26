# Single database repository boundary

## Goal

Create the smallest repository seam that stores local-only history, synced replicas, and local upload/error state in one PowerSync SQLite authority.

## Dependencies

powersync-db-encryption.

## Requirements

- One schema defines distinct local-only, synced, and upload/error roles without a second writable database.
- Existing UI-facing repository semantics are adapted at one boundary rather than copied into each screen.
- Synced and local representations of one logical capture deduplicate deterministically.
- Freeze typed dependency-injection seams for admission, read-only import,
  account-scoped cache, backfill candidate/checkpoint access, and upload
  settlement so later leaves can consume the repository without editing its
  owner files.
- Repository storage and settlement I/O are injected protocol dependencies so
  deterministic fault controls do not require later owner-file changes.

## Acceptance criteria

- [ ] Local-only insert/read works before login and does not create a synced row.
- [ ] Eligible synced state and local capture merge into one logical repository result.
- [ ] Tests reopen the database and prove all roles survive without consulting legacy GRDB.

## Out of scope

- No production Store or UI wiring in WP1.
- No mirror write to PasteBuddyDatabase.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
