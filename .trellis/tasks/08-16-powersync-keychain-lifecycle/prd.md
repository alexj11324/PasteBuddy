# Keychain database key lifecycle

## Goal

Own the local database key in Keychain with explicit first-create, load-existing, unavailable, corrupt, and authorized-reset behavior.

## Dependencies

powersync-db-encryption.

## Requirements

- Keychain lookup is keyed by stable bundle/account-neutral database identity and returns typed states.
- Only an explicit first-create path may generate a key; load-existing never generates one.
- Reset is a separate authorized API and never runs as error recovery.

## Acceptance criteria

- [ ] First create persists one key and subsequent loads return identical bytes.
- [ ] Missing/corrupt/inaccessible key for an existing database propagates fail closed through the database opener.
- [ ] Logs and diagnostics expose state/error codes but never raw key bytes.

## Out of scope

- No in-memory or UserDefaults fallback.
- No silent Keychain item replacement.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
