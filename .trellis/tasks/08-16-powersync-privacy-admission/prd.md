# Zero-network privacy admission

## Goal

Put one admission decision before every PoC network-capable path so sensitive, excluded, signed-out, and sync-disabled content remains local-only.

## Dependencies

powersync-repository-boundary.

## Requirements

- Admission reuses SensitiveContentDetector and PrivacyConfiguration rather than creating a second detector.
- The decision is persisted with the local item before any enqueue/connect/upload call.
- Tests use an injected network recorder and assert zero calls, not merely zero successful responses.

## Acceptance criteria

- [ ] Every sensitive/excluded fixture creates zero PowerSync, Supabase, Storage, and AI recorder calls.
- [ ] Signed-out and sync-disabled eligible fixtures remain readable locally with zero synced rows.
- [ ] Changing eligibility later requires an explicit user-approved/backfill path rather than automatic upload.

## Out of scope

- No payload logging or fixture with a real secret.
- No network call followed by client-side discard.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
