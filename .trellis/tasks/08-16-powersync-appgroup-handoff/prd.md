# Encrypted App Group handoff

## Goal

Provide authenticated encrypted extension-to-main-app handoff without giving extensions PowerSync database access.

## Dependencies

powersync-keychain-lifecycle and powersync-connect-owner.

## Requirements

- Handoff payloads include version, nonce, ciphertext, authentication tag, source kind, and idempotency identifier.
- Only the main app decrypts and consumes entries; successful consumption is idempotent and removes the entry.
- Key material is Keychain/App Group-access controlled and never stored beside payload files.

## Acceptance criteria

- [ ] Keyboard/share/action test payloads round-trip and duplicate delivery imports once.
- [ ] Tamper, wrong key, partial write, and crash-before-ack fail closed and remain observable.
- [ ] A byte scan of App Group test storage finds none of the plaintext fixture.

## Out of scope

- No plaintext JSON sidecar containing clipboard data.
- No extension database open or network call.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
