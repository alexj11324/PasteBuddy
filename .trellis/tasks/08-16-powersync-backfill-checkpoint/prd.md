# Backfill ordering and checkpoints

## Goal

Backfill all eligible retained history newest-first in 100-item batches with durable pause, quit, relaunch, and resume checkpoints.

## Dependencies

powersync-grdb-migration and powersync-account-confirmation.

## Requirements

- Order by max(createdAt, updatedAt) descending with a stable tie-breaker.
- Select the next batch only after the prior batch is durably acknowledged/settled.
- Checkpoint state is account-scoped and never embeds clipboard payloads.

## Acceptance criteria

- [ ] At least 201 fixture items upload in exact newest-first batches of 100,100,1 without gaps or duplicates.
- [ ] Pause and process termination at each boundary resume from the last durable checkpoint.
- [ ] Adding newer local content during backfill follows the documented stable ordering without invalidating completed work.

## Out of scope

- No load-all-history array or unstable timestamp-only cursor.
- No selection of batch N+1 before N is settled.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
