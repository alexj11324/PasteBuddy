# Legacy GRDB read-only migration

## Goal

Import a real current legacy GRDB fixture into the PowerSync repository while proving the source is never written and no dual authority remains.

## Dependencies

powersync-repository-boundary.

## Requirements

- Open the legacy database read-only and reject schema versions outside the supported manifest.
- Migration is resumable/idempotent and records source identity plus imported counts without payload evidence.
- After verified completion, runtime reads use only the PowerSync repository.

## Acceptance criteria

- [ ] Representative text, image reference, pinned, deleted, and metadata rows migrate exactly once.
- [ ] Source database digest and modification metadata are unchanged after success and injected failure.
- [ ] Relaunch resumes from the durable migration marker without duplicate logical items.

## Out of scope

- No write, vacuum, migration, or WAL checkpoint against the legacy file.
- No fallback UI read from legacy GRDB after completion.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
