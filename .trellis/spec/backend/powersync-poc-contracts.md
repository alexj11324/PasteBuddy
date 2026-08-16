# PowerSync PoC executable contracts

## Scenario: Local-first PowerSync admission and settlement

### 1. Scope / Trigger

This spec applies to WP1 PoC code that opens the PowerSync database, admits a
clipboard item to cloud sync, migrates legacy GRDB data, uploads queued CRUD,
handles attachments, or connects a macOS/iOS client. It does not authorize
WP2 production schema or UI work.

V1 server orchestration uses Deno/TypeScript Supabase Edge Functions. This
spec prohibits a standalone Rust backend and a Rust rewrite of PowerSync.
Rust-to-Wasm is allowed only in a separately approved performance task after
profiling and an isolated benchmark prove a pure-compute bottleneck misses a
frozen Gate.

### 2. Signatures

The exact Swift types may be introduced by their owning leaf task, but the
responsibilities must remain equivalent to:

- PowerSyncDatabaseKeyStore.loadExistingKey() -> Data
- EncryptedPowerSyncDatabase.open(path:key:) -> database or typed failure
- PowerSyncConnectionOwner.connect(account:) / disconnect()
- CloudSyncAdmissionPolicy.decision(item:session:settings:) -> localOnly or sync
- PowerSyncClipboardRepository.upsertLocal / enqueueCloud / settleUpload
- RepositoryAdmissionSink.admit(decision:item:)
- LegacyImportSink.importBatch / markMigrationCheckpoint
- AccountReplicaStore.clearDownloadedCache / queryAccountReplica
- BackfillCandidateStore.nextCandidates / markBackfillCheckpoint
- UploadSettlementStore.recordRejection / settleUpload
- LegacyGRDBImporter.importReadOnly(source:sink:)
- BackfillCoordinator.nextBatch(limit: 100) / markCheckpoint
- AttachmentTransport.reserve / upload / commit / cancel

The SDK-linkage owner must create the shared `PasteBuddyPowerSyncPoCTests`
test target and the `PasteBuddyPowerSyncHostedMacPoC` executable target before
any dependent leaf starts. Database, connector, repository, and attachment
owners must expose injected protocols rather than static/global I/O. Wave 10
fault controls implement those committed protocols; they may not reopen owner
files to add test-only hooks.

No extension-facing API may expose the PowerSync database or connect method.

### 3. Contracts

- One PowerSync SQLite file is the runtime local authority.
- Database key material is Keychain-only. A missing, corrupt, or wrong key for
  an existing file fails closed and preserves that file.
- The main app is the sole connect owner.
- Extension input is authenticated encrypted handoff data. Plaintext payloads
  are not written to App Group storage.
- Sensitive, excluded, signed-out, or sync-disabled items are local-only and
  never enter a synced table or network-capable queue.
- Cloud IDs include account identity deterministically and cannot collide
  across accounts.
- Backfill is max(createdAt, updatedAt) descending, 100 items per checkpointed
  batch.
- Permanent cloud rejection is settled and surfaced locally; temporary failure
  remains retryable without blocking unrelated settled work indefinitely.

### 4. Validation & Error Matrix

| Condition | Required result |
| --- | --- |
| Existing encrypted DB plus missing/wrong key | Typed fail-closed error; original bytes unchanged; no replacement DB |
| Extension attempts database connect | Rejected before database open |
| Sensitive/excluded item | localOnly; zero PowerSync/Supabase/Storage requests |
| Signed-out or sync disabled | localOnly; zero cloud queue rows |
| Account changes without confirmation | No connect, backfill, or upload |
| Duplicate client mutation | One logical cloud result |
| Permanent quota/policy rejection | Queue entry settled; local error visible; later work proceeds |
| Temporary transport failure | Retryable; no false permanent error |
| Attachment helper fails a required case | Freeze signed-URL fallback; do not patch the helper repeatedly |
| Developer prefers Rust but no measured bottleneck exists | Keep TypeScript; do not add a Rust/Wasm task |
| Profiling identifies pure compute that misses a frozen Gate | Create a separate Rust/Wasm evaluation task; do not modify the current leaf |

### 5. Good / Base / Bad Cases

- Good: An eligible item is visible locally immediately, later uploads once,
  and appears on the second device after reconnect.
- Base: A signed-out or excluded item remains fully usable in local history and
  creates no cloud traffic.
- Bad: Opening an existing database with a missing key creates a new empty
  database, an extension connects directly, or quota rejection blocks the
  entire queue forever.

### 6. Tests Required

- Unit: typed admission decisions, key lifecycle, account-scoped IDs, batch
  ordering, quota classification, and checkpoint replay.
- Integration: encrypted database bytes and reopen, read-only GRDB import,
  extension handoff, duplicate settlement, attachment state transitions.
- Runtime: real macOS and iOS Simulator against independent hosted Dev
  services; offline, kill, missed notification, reconnect, 5,000 items, and
  redacted network observation.

Assertions must prove state and side effects, not source-token presence.

### 7. Wrong vs Correct

Wrong: one task adds the SDK, encryption, migration, account switching,
backfill, attachments, and two-platform hosted tests before any checkpoint.

Correct: one leaf introduces one owner or invariant, proves it, and commits it
before the next dependent leaf begins. Independent leaves may run in two
isolated worktrees, but the Coordinator integrates their commits in canonical
order and runs a combined wave Gate.

Wrong: catch a key/decryption error and create an empty database so the app can
continue.

Correct: preserve the existing database, expose a typed recoverable error, and
require explicit user recovery.

Wrong: add an Axum service or Rust/Wasm module because Rust is generally fast.

Correct: keep I/O orchestration in TypeScript; require profiling, a missed
quantitative Gate, and an isolated benchmark before proposing Rust/Wasm.
