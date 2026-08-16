# Encrypted database open fail closed

## Goal

Prove an encrypted PowerSync SQLite database opens, reopens with the same key, and preserves the original file on key or decryption failure.

## Dependencies

powersync-sdk-linkage.

## Requirements

- One opener owns initial encryption pragmas and file-existence checks.
- The opener implements an injected database-opening protocol so fault tests
  can control open, I/O, and interruption outcomes without editing this owner.
- An existing database with a missing or wrong key returns a typed error before any replacement/create path.
- Tests compare file identity or digest before and after every failure.

## Acceptance criteria

- [ ] Correct key creates once and reopens the same rows.
- [ ] Missing, malformed, and wrong keys fail closed while the existing database bytes remain unchanged.
- [ ] No catch path creates a new empty masking database.

## Out of scope

- No Keychain implementation yet.
- No automatic delete, rename, reset, or empty-database fallback.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
