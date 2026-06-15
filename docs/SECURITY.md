# PasteBuddy Security Baseline

PasteBuddy treats clipboard history as high-sensitivity local user data.

## Current Local MVP

- The durable snapshot supports two explicit modes: standard local storage and
  encrypted local storage. Standard mode avoids Keychain prompts in unsigned
  debug builds and does not claim app-level AES-GCM protection. Encrypted mode
  writes the snapshot as an AES-GCM envelope.
- When encrypted mode is enabled, the encryption key is generated locally and
  stored separately in Keychain with this-device-only accessibility. Keychain
  lookups do not request system authentication UI; if macOS requires
  interaction, PasteBuddy surfaces a safe error instead of showing an
  unexpected login-keychain password prompt.
- Users can enable an optional Touch ID history lock. This protects access to
  history, search, pinboards, and visible metadata with a configurable grace
  period without tying normal app launch to Keychain authentication.
- Signed production builds can use `EncryptionService.secureEnclaveProtected()`
  or `EncryptedSnapshotStore.secureEnclaveProtectedDefaultStore()` so the
  AES-GCM key is stored as a Secure Enclave wrapped key instead of raw key
  bytes in a generic-password item.
- Legacy plaintext snapshot files are treated as migration inputs when the
  target storage mode is encrypted. In encrypted mode, successful load rewrites
  them as AES-GCM envelopes; in standard mode, plaintext local storage is an
  explicit user-visible choice rather than a silent downgrade.
- Legacy `clipboard.pbenc` files are not auto-opened by the default standard
  startup path. Importing or continuing an older encrypted store must be an
  explicit encrypted-mode action because it can require Keychain access.
- `EncryptedSnapshotStore.rotateEncryption(to:)` supports local key rotation by
  decrypting with the current key, re-encrypting with a new `EncryptionService`
  key ID/account, and replacing the existing store atomically.
- In encrypted mode, clipboard text, HTML/RTF rich variants, URLs, file
  references, image bytes, OCR metadata, pinboards, privacy settings, custom
  capture rules, user titles, item labels, and reusable content categories are
  inside the encrypted snapshot.
- Search uses decrypted in-memory data after local authorization; no plaintext search index is written to disk.
- Screenshots and images trigger local Apple Vision OCR after capture when OCR is enabled.
- Sensitive app capture exclusion supports both app display names and bundle identifiers, with default password-manager exclusions.
- Capture can be paused indefinitely or for a timed local window, and text, links, files, and images can be disabled independently.
- Custom capture rules run locally before new items enter history. Rules can block text, regex matches, source app names, source bundle identifiers, URL hosts, and file extensions, and are stored only inside the encrypted snapshot.
- Local sensitive-text heuristics block obvious passwords, API tokens, private keys, one-time codes, and likely payment card numbers before they enter the encrypted store.
- Manual history entry, Share/Action imports, and Shortcuts item creation use the
  same local privacy decision path for content-type toggles, sensitive-text
  blocking, and custom capture rules before anything is written to history,
  pinboards, or the searchable in-memory index.
- `PrivacyPostureReport` exposes the current paused state, disabled content
  types, excluded app counts, active rule count, and the protected surfaces
  covered by the same local privacy boundary: automatic capture, manual
  history, pinboards, search, Shortcuts, keyboard insertion, Share/Action
  imports, and MCP access.
- Direct paste falls back to copy-only unless macOS Accessibility access is
  granted for Command-V event injection, and only transient paste-result status
  is kept in UI state.
- Sync and shared pinboards default to local-only and are blocked until CloudKit capability and end-to-end key hierarchy configuration are present.
- Cloud sync upload packages contain encrypted snapshot envelopes only; raw clipboard items are not an upload boundary.
- CloudKit upload/download uses an encrypted remote-record boundary; the real CloudKit adapter only saves/fetches encrypted records and non-sensitive routing metadata.
- Encrypted sync imports merge history and pinboard records from decrypted packages without allowing remote devices to overwrite local privacy settings.
- CloudKit preflight diagnostics explain missing opt-in, container, key
  hierarchy, entitlement, first-sync, and conflict-review states without
  exposing clipboard payloads or enabling plaintext fallback.
- Shared pinboard metadata, participants, permissions, link-token hashes, and
  wrapped board keys are stored inside the encrypted snapshot; raw share-link
  tokens and unwrapped board keys are not persisted.
- Shared pinboard key exchange uses Curve25519 key agreement, HKDF-SHA256, and
  AES-GCM wrapped board keys so participants can receive a board key without
  storing it in plaintext.
- Shared pinboard invitation packages are recipient-scoped and contain public
  identities, permissions, key fingerprints, and AES-GCM wrapped board keys.
  They do not contain unwrapped board keys, private key material, or pinboard
  item contents.
- CloudKit invitation records expose only routing metadata plus encoded public
  identity or invitation package data; tests assert that private keys, unwrapped
  board keys, and pinboard names are not written to those records.
- CloudKit invitation subscriptions use recipient public-key fingerprints and
  silent content-available notifications only; notification alert bodies must
  not contain clipboard, OCR, pinboard, board-key, or private-key material.
- Pending shared pinboard invitations are stored in the encrypted snapshot inbox
  with local pending/accepted/rejected/expired status. Background refresh must
  not spill invitation packages into plaintext temporary files or logs.
- CloudKit invitation notification handling validates the subscription's
  recipient public-key fingerprint against the local identity before fetching or
  saving invitation packages.
- iOS app and extension targets must use `EncryptedSnapshotStore.appGroupStore(groupIdentifier:)` with App Group entitlements to share the encrypted snapshot; extension handoff must not use plaintext temporary files.
- Local MCP access is disabled by default, uses stdio, has per-tool opt-in, and
  keeps search summary-only. The separate `pastebuddy.retrieve_item` payload
  tool is disabled by default and omits image bytes unless a call explicitly
  requests them.
- MCP read paths re-apply the current local privacy rules before returning
  search summaries, item payloads, pinboard counts, or pin-first-match results.
  This prevents a later disabled content type, source exclusion, sensitive-text
  rule, or custom capture rule from being bypassed by an existing history item.
- MCP access audit entries are encrypted with the local snapshot and include
  metadata only: tool, time, outcome, item/pinboard IDs, result count, and
  payload/image inclusion flags. They must not store query text, clipboard
  payloads, OCR text, URLs, file contents, or image bytes.
- Monetization state is limited to local entitlement metadata. In encrypted
  mode it is covered by the AES-GCM snapshot; PasteBuddy never stores payment
  cards, App Store signed transactions, billing tokens, or invoice credentials.
- `EncryptionCoverageAudit` enumerates the sensitive data surfaces that must
  remain encrypted when encrypted storage is enabled.
- Corrupted or undecryptable store files surface a safe unreadable-store error.
  The app keeps the in-memory default snapshot instead of exposing partial
  plaintext or crashing.
- Storage retention, max-size pruning, and clear-history controls preserve pinned items by default while removing normal unpinned history. Removing pinned item memberships requires the explicit all-history action.
- Plain-text paste is a pasteboard write mode only; it does not rewrite the encrypted original item payload.
- Multi-select paste aggregates selected items in memory and writes only the requested pasteboard representation.
- Manual item creation, text edits, and undo delete all write back through the
  current snapshot store mode.
- Pinboard reorder, recolor, and move operations only mutate encrypted organization metadata and item references.

## Key Hierarchy And Downgrade Rules

- Local data key: a per-device 256-bit AES-GCM key generated with Security
  framework randomness. The key is kept in Keychain, or wrapped by a Secure
  Enclave private key when the signed target opts into the protected store.
- Local key identity: encrypted envelopes store a non-secret key ID such as
  `local-primary-v1` or `local-secure-enclave-v1`; key bytes are never written
  beside the ciphertext.
- Rotation: create a new `EncryptionService` with a new key ID/account, call
  `rotateEncryption(to:)`, then delete retired key material only after the new
  envelope has been verified.
- Sync key hierarchy: CloudKit packages require a positive
  `keyHierarchyVersion`, a configured container identifier, and verified
  CloudKit capability before any upload or import. Mismatched container or key
  hierarchy versions are rejected.
- Shared pinboard keys: every shared board uses recipient-scoped Curve25519 key
  agreement plus AES-GCM wrapped board keys. Unwrapped board keys and private
  keys are not stored in CloudKit records, notification payloads, logs, or
  temporary files.
- Plaintext downgrade: sync packages, CloudKit records, and shared pinboard
  transport have no plaintext fallback path. Local standard storage is a
  user-visible mode for this device only; it must not be used to justify
  plaintext CloudKit upload, shared pinboard transport, or MCP export.

## Threat Model

- Local disk access: in encrypted mode, an attacker who reads the Application
  Support store should only see an encrypted envelope and non-secret routing
  metadata. In standard mode, users trade app-level encryption for less
  intrusive local operation and should not treat the store as protected from
  local disk readers.
- Stolen device: Keychain this-device-only accessibility limits direct key
  export. Secure Enclave protected builds further wrap the AES-GCM key with
  non-exportable private-key material.
- Cloud storage exposure: iCloud/CloudKit receives encrypted snapshot envelopes
  and routing metadata only. Clipboard payloads, OCR text, pinboard item
  contents, search indexes, and raw board keys are not CloudKit fields.
- Shared collaborator access: collaborators receive only invitation packages
  scoped to their public identity and permission level. Removing a participant
  revokes future local access metadata; full cryptographic rekey of already
  delivered board content remains a signed-app sharing recovery task.
- Debug, logs, analytics, and crashes: no telemetry or crash-reporting
  integration is present. Future telemetry must pass a plaintext-leak review
  and may only record aggregate metadata that excludes clipboard payloads,
  OCR text, URLs, file contents, image bytes, search query text, and keys.
- Temporary files: test/probe artifacts stay under `tmp`; production import,
  extension, sync, and sharing flows must use encrypted envelopes rather than
  plaintext handoff files.
- Lost keys, logout, restore, and corruption: unreadable encrypted records are
  detected and surfaced as safe errors. The local MVP provides preflight and
  unreadable-store diagnostics; signed-account recovery UX requires Apple
  identity, CloudKit account, and product policy wiring.
- Legacy data: plaintext snapshots are accepted for standard local storage or
  for one-time migration into encrypted mode. Failed encrypted migration blocks
  loading rather than silently claiming encryption.

## External Configuration Still Required

- Signed-app CloudKit container/account wiring, deployed public database schema,
  public-key directory deployment, and push/background registration.
- User-facing CloudKit account, corruption, logout, restore, participant
  removal rekey, and lost-key recovery UX beyond the local diagnostics above.
- App Store privacy review for any future telemetry, crash reporting, or
  analytics integration.
