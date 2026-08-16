# Hosted macOS sync path

## Goal

Run the PoC on macOS against independent Supabase Dev and PowerSync Cloud and prove the basic local-first round trip.

## Dependencies

powersync-attachment-decision.

## Requirements

- Use Dev/Alpha resources only and obtain credentials through approved secret injection; no secret is persisted.
- Run from a dedicated PoC identity/data directory, not /Applications/PasteBuddy Dev.app.
- Record local insert, offline state, upload, remote echo/download, and relaunch evidence.

## Acceptance criteria

- [ ] One macOS client writes locally while offline, reconnects, uploads once, and retains the item after relaunch.
- [ ] Sensitive fixture requests remain zero in redacted network observation.
- [ ] Exact source commit, bundle/process identity, local DB path, hosted project, and timings are recorded.

## Out of scope

- No production bundle, production account, or stable PasteBuddy Dev install overwrite.
- No mock transport as Pass evidence.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
