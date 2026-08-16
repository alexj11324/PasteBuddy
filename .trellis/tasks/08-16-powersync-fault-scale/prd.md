# Fault injection and scale gate

## Goal

Exercise the completed PoC under failure, concurrency, process death, 5,000-item backfill, and attachment load before review.

## Dependencies

powersync-hosted-macos and powersync-hosted-ios.

## Requirements

- Use deterministic barriers or service controls for concurrent/failure cases; sleeps alone are not proof.
- Measure omission, duplicate, latency, queue depth, database integrity, and recovery.
- All evidence uses synthetic non-sensitive fixtures and redacted logs.

## Acceptance criteria

- [ ] Offline, missed notification, duplicate/retry, kill/relaunch, and reconnect end with omission=0 and duplicate=0.
- [ ] 5,000 items and 250,000,000 attachment-byte boundary complete/pause/resume without corruption, deadlock, or unrecoverable SQLITE_BUSY.
- [ ] Any sensitive/excluded fixture produces zero provider, Supabase, PowerSync, and Storage calls.

## Out of scope

- No production load test or real clipboard data.
- No timing-only race test without a barrier/observable state.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
