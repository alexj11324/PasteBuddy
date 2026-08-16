# PasteBuddy security and privacy contract

## Status

This document freezes the Supabase target security boundary for WP0. Existing
local encryption, CloudKit, MCP, StoreKit, and gateway code remains in the
repository as migration input; this document does not claim that the target is
implemented.

Normative terms are **MUST / SHALL**. Candidate model choices and operational
values are explicitly marked tentative.

## Data classification and encryption

PasteBuddy treats clipboard history as high-sensitivity user data.

1. The client MUST inspect content and privacy policy before any remote
   request. Sensitive text, credentials, tokens, private keys, one-time codes,
   payment data, and content rejected by a user rule MUST never leave the
   device.
2. Accepted raw text, structured values, file bytes, and image bytes MUST be
   encrypted client-side with AES-256-GCM before Postgres or private Storage.
   Each envelope carries ciphertext, nonce, AAD, and key version.
3. The service hosts recovery material. This is **server-recoverable
   encryption**, not E2EE. Product, legal, UI, and review copy MUST never call
   it end-to-end encryption or imply that the service cannot recover data.
4. A ciphertext integrity failure, AAD mismatch, unsupported key version, or
   decrypt failure MUST fail closed. No plaintext fallback, partial record, or
   guessed key is allowed.
5. The local no-account mode remains complete. Local standard/encrypted storage
   choices do not authorize plaintext cloud upload.

The service-visible derived boundary is separate: a compliant original may be
handled only transiently in an entitled Cloud AI Edge request. It MUST NOT be
persisted in a request log, queue, cache, database, Storage object, or
analytics event. Redacted semantic documents, semantic FTS, vectors, policy
metadata, and ranks are visible to the service and are not raw content.

## Supabase and Storage boundary

The cloud deployment uses a new independent PasteBuddy Supabase project in
us-east-1 and never reuses another product's project. Free is Dev/Alpha only;
Pro is required before a formal paid launch. Per account limits are 5,000 cloud
clipboard items and 250 MB attachments. Quota exhaustion stops new cloud
uploads but never deletes local history or existing cloud data. Local history
is unlimited by product count.

api user-owned tables have RLS enabled and deny-by-default policies. Direct
api table CRUD is not exposed in V1; the approved Data API function allow-list
is limited to mutation/cursor/export/reset-fence RPCs, with explicit
authenticated EXECUTE grants. Device proof, registration, and account-key
delivery are authenticated Edge endpoints backed by private metadata
transactions, not Data API RPCs. Asset reserve/commit are also Edge
endpoints.
Anonymous callers have no access. The public schema contains no PasteBuddy
business tables or RPCs. The
private schema has no Data API, Realtime, anon, or authenticated table
exposure. Every exposure, GRANT, RLS policy, bucket, and internal function
must be reviewed explicitly.

The attachment bucket is private. SQL/Data API RPCs never sign Storage URLs.
`POST /functions/v1/asset-upload-reserve` is an authenticated Edge flow: it
checks `cloud_sync`, calls a private reservation transaction, then signs only
the exact ciphertext object with a short TTL using the Edge Storage service
client. Signer failure cancels the reservation. Commit uses
`POST /functions/v1/asset-upload-commit`, which rechecks owner, reservation,
exact object path, size, and ciphertext hash before a private commit
transaction. `POST /functions/v1/asset-download-capability` is a separate
valid-identity owner flow for encrypted exports after expiry; it signs an
exact object with a short TTL and is a replayable bearer URL until expiry when
Storage cannot guarantee single-use. `api.export_encrypted` returns IDs and
metadata only. URLs/tokens are never logged or persisted. Uncommitted objects
older than 24 hours are orphan-cleanup candidates. Public URLs, unrestricted
listing, plaintext objects, and reusable upload tokens are forbidden.

Supabase Realtime is notification-only and carries a revision, not row data.
Reconnects and all notifications invoke cursor pull. This migration does not
modify the Realtime schema or pin an extension version.

## Authentication and entitlement

Apple, Google, and Magic Link identities resolve to one Supabase user_id.
StoreKit appAccountToken is that UUID. An Edge verifier validates signed
transactions and persists normalized facts only; raw signed transactions,
payment-card data, and billing credentials are not stored.

Every transaction update or restore recomputes all valid transactions. A single
expired/revoked transaction cannot overwrite another valid transaction. Local
simulated trial, installation date, cached embeddings, API keys, and product
lookups are never entitlement evidence.

The entitlement result is decomposed into independent capabilities:

- `cloud_sync`: active Cloud subscription or active BYOK Annual;
- `platform_ai`: active Cloud subscription only;
- `byok_ai`: active BYOK Annual only;
- `local`: no account required and never proof of remote access.

Sync push/upsert RPCs and encrypted cloud migration require `cloud_sync`;
owner-scoped `pull_changes` and `ack_revision` require only a valid identity
session plus enabled-state, generation, fence, and RLS checks. The authenticated
semantic-search Edge endpoint requires `platform_ai` or `byok_ai`, and chooses
the matching provider route. BYOK Vault retrieval/use requires `byok_ai`.
Every RPC/Edge operation checks its named capability rather than treating any
active subscription as universal access. All three remote capabilities become
false immediately at expiry, revocation, suspension, or failed entitlement
refresh. Cloud writes, AI, and **all remote Vault secret retrieval/use** lock;
local capture/history and local decryption with an already cached account key
remain available. A new device cannot recover an account key from Vault after
expiry. Explicit authenticated cloud deletion or secret destruction remains a
cleanup operation and is not secret retrieval/use. The old fixed-ten-minute
gateway JWT is not a security boundary. A Supabase identity JWT remains usable
for authenticated owner-scoped encrypted `pull_changes`, cursor ACK,
`export_encrypted`, deletion, and cleanup after commercial expiry, but never
grants cloud_sync, AI, Vault, or BYOK use. Export may return only the user's
encrypted envelopes and attachment IDs/metadata; a separate identity-only
Edge signer issues any short-lived exact-object download URL. It never returns
plaintext or key material.
Short-lived operation capability assertions are checked before and after every
remote await and cannot outlive the entitlement check that authorized them.

Initial provisioning uses authenticated `POST /functions/v1/initial-enable`
with `{ idempotency_key, scope, device_id, platform,
device_signing_public_key, device_key_agreement_public_key, challenge_id,
proof_signature, request_context_hash }`. The Edge may perform a
non-authoritative cryptographic precheck, but the authoritative transaction
locks state and then checks the short-lived single-use
`purpose=register` challenge, the UUID is unbound or same-user, challenge CAS,
proof, consumption, and bootstrap-row creation together. The same
proof/idempotency is retryable; a cross-user UUID or different key fails
closed. For cloud bootstrap, bind-if-absent creates the initial device; semantic
bootstrap requires an existing same-user non-revoked device and never replaces
its keys. Each scope is initialized only
once, with a durable bootstrap operation and cloud generation/account-key
version or AI generation/identity. The response contains no key material;
`POST /functions/v1/account-key-delivery` must succeed before SyncCoordinator
starts the pausable initial backfill. The operation is observed through
`GET /functions/v1/initial-enable-status?operation_id=...`. A different
idempotency key after initialization fails closed. Later devices use
authenticated `POST /functions/v1/register-device` with platform, both public
keys, the byte-exact v1 IEEE-P1363 proof, and active `cloud_sync`; this
endpoint is not a Data API RPC.
Expired accounts cannot register or retrieve a key, and reset-required
devices must use the reset-fence ACK path.

Supabase Edge functions run in the Supabase Deno-compatible TypeScript runtime.
Node 22+ and TypeScript 5 apply only to repository Node tooling, the legacy
gateway, or CI dependencies that actually use supabase-js. If management
tooling later invokes Supabase Management OAuth /v1/oauth/token, any successful
2xx response is accepted; this is not a StoreKit/Auth entitlement criterion.

## AI privacy boundary

Platform and BYOK AI use only OpenRouter with provider.zdr=true and
data_collection=deny. A provider/embedding allowlist capability probe MUST
verify both flags for the selected route; absence of a verified zero-retention
route fails closed, with no silent provider downgrade and no BYOK bypass.

The client performs its sensitive-query gate and calls only the authenticated
Edge semantic-search endpoint with `query`, `filters`, and `limit`. The Edge
revalidates session and the selected `platform_ai` or `byok_ai` capability
before the provider request and again after every provider await. Trusted Edge
then creates an internal request ID and canonical request hash over the
verified user, active identity, indexing generation, semantic query, filters,
and limit (not raw clipboard content), binds both to a short-lived, single-use
`private.operation_capability_assertions` row, and calls the restricted
database RPC with `p_user_id`, `assertion_id`, `p_request_id`,
`p_request_hash`, `query_embedding` as `halfvec(1024)`, `semantic_query`,
`filters`, and `limit` through the trusted service path. The RPC consumes the
assertion atomically and rejects missing, wrong-user/capability/request/hash,
expired, revoked, or consumed assertions; `service_role` alone is not a
capability. The RPC is not a client Data API function, has no
anonymous or authenticated execution grant, never calls a provider, and
hard-scopes every vector/FTS query to the Edge-verified `p_user_id`. The
function is `private.match_clipboard`; the private schema is never Data API
exposed.

The AES-256-GCM account data encryption key is separate from BYOK. Supabase
Vault creates/authorizes the key flow and stores the account-key recovery copy,
while api.account_keys stores
key_version, rotation_status, and non-secret metadata. An authenticated
authorized device may receive actual key material only through
`POST /functions/v1/account-key-delivery` while `cloud_sync` is active and
stores it in Keychain or secure storage; the service can recover it. Rotation
creates and activates a new
version while the old version becomes retiring and remains
decryptable/recoverable. Only after reencryption, required device
acknowledgement, and a safe rotation gate does it revoke/delete the old
reference. A new device is denied remote account-key recovery after expiry;
subscription expiry does not erase key material already cached locally. The
delivery endpoint accepts `{ device_id, enrollment_generation,
requested_key_version, challenge_id, proof_signature, request_context_hash,
idempotency_key }`, requires a fresh `purpose=key_delivery` challenge,
current reset ACK, same-user/non-revoked device, and active `cloud_sync`. It
reads the original account key only from Vault inside Edge, then returns a
no-store device-bound envelope built with the registered key-agreement key,
ephemeral P-256 ECDH, HKDF-SHA256, and AES-256-GCM; AAD binds
user/device/enrollment/key version/challenge/delivery ID. The response
contains only delivery metadata, ephemeral ECDH public key, nonce, ciphertext,
tag, AAD, and expiry. The original account key exists remotely only in Vault;
it never appears in HTTP, logs, or the delivery ledger. The in-memory
envelope and URL are never logged or persisted. Active or authorized
retiring versions may be delivered; revoked versions, replayed challenges,
old enrollment, wrong device, key mismatch, and expiry fail closed. The
client decrypts in memory and writes only to Keychain/secure storage; separate
signing and key-agreement P-256 private keys are held in Secure Enclave or,
when unavailable, Keychain-protected storage.

The proof wire contract is byte-exact: UUIDs are RFC4122/network-order 16 raw
bytes; `purpose` is register `0x01` or key_delivery `0x02`; `scope` is
cloud_sync `0x01` or semantic_index `0x02`; `platform` is macOS `0x01` or iOS
`0x02`. Each public key is exactly X9.63 uncompressed 65 bytes
(`0x04||X32||Y32`), on-curve/non-infinity, and its fingerprint is
base64url-no-pad(SHA-256(the 65 bytes)). The client signs
`ASCII("PasteBuddyDeviceProof/v1")||0x00||userUUID16||deviceUUID16||purposeU8||challengeUUID16||SHA256(rawNonce)||requestContextHash32`;
the ECDSA P-256/SHA-256 signature is raw IEEE-P1363 `r32||s32` (64 bytes),
not DER. Register context is
`ASCII("PasteBuddyRegisterContext/v1")||0x00||scopeU8||platformU8||signingX96365||agreementX96365||idempotencyUUID16`;
key-delivery context is
`ASCII("PasteBuddyKeyDeliveryContext/v1")||0x00||enrollmentUUID16||u32be(keyVersionUTF8ByteCount)||keyVersionUTF8||idempotencyUUID16`,
with key version ASCII `[A-Za-z0-9._-]{1,64}`. JSON binary uses
base64url-no-padding; malformed length/encoding/point/context/signature
fails closed.

The account-key envelope uses the agreement key, not the signing key. ECDH is
the 32-byte big-endian X coordinate/256-bit deriveBits result, left-padded
with zeros; invalid points and all-zero shared secrets fail. AAD is
`ASCII("PasteBuddyAccountKeyEnvelope/v1")||0x00||userUUID16||deviceUUID16||enrollmentUUID16||u32be(keyVersionByteCount)||keyVersionASCII||challengeUUID16||deliveryUUID16`.
HKDF-SHA256 uses IKM=ECDH32, salt
`SHA256(ASCII("PasteBuddyKeyWrapSalt/v1")||0x00||deliveryUUID16||challengeUUID16)`,
info=AAD, and L=32. Plaintext is exactly 32 bytes; AES-256-GCM uses a random
12-byte nonce, 16-byte tag, and 32-byte ciphertext. `expires_at` is RFC3339
UTC metadata only. CryptoKit and Deno WebCrypto must cross-verify fixed
non-secret WP2 vectors; DER-to-P1363 conversion, if needed, is explicit and
tested.

BYOK annual V1 is OpenRouter-only and unlocks use of the user-supplied
credential. The raw key is stored in Supabase Vault, while api.ai_profiles
stores only fingerprint and status. The only opaque Vault reference is
private.vault_secret_refs.vault_secret_ref: account_data_key mappings require
account_key_id and have one active reference per account-key version;
byok_openrouter_key mappings have null account_key_id and at most one active
reference per user.
Custom provider URLs, arbitrary hosts, and independent provider endpoints are
forbidden. This removes the previous custom-http-URL key/content leakage path.
The client can test, replace, or destroy the credential but never reads it
back. private.vault_secret_refs.secret_kind distinguishes account_data_key from
byok_openrouter_key. BYOK expiry/revocation disables use immediately; explicit
BYOK deletion destroys only that Vault secret and fingerprint.

Platform and BYOK embeddings are exactly 1024 dimensions. Each account has one
active embedding identity. Changing the model, tokenizer, or identity marks
old vectors stale and schedules a full resumable rebuild. Every provider-await
return and semantic document/vector write performs a database-atomic check of
user/item ownership, AI processing enabled, active identity, and indexing
generation; a failed check returns `AI_GENERATION_STALE` with no commit.
Semantic-index deletion disables processing and bumps generation before task
cancellation or artifact deletion. Qwen3 Embedding is
the default candidate; gte-small is not a candidate. Model selection remains
open until all bake-off gates pass:

- strict JSON validity at least 99.5%;
- sensitive-content leakage exactly 0;
- Recall@5 at least 0.85;
- nDCG@5 at least 0.80.

Among candidates meeting every gate, the selected model is the one with the
lowest cost per qualified request. The record must include policy/model
version, retention proof, latency, cost, and failures.

UI semantic retrieval is a user-clicked sparkle action, never typeahead or an
Enter shortcut. The client fuses three independent lists: server vector,
server semantic FTS, and local lexical SQLite. FTS cannot be folded into the
local lexical list. MCP is an explicit tool invocation, not a sparkle click,
but follows the same retrieval contract. ready=0, offline, partial, failed, no
relevant result, and user exclusion are distinct states.

## Synchronization and lifecycle

SQLite is the only client read source for UI, offline, and the sync queue.
Supabase Postgres is the logged-in account cloud authority. One
SyncCoordinator actor owns enqueue, drain, scheduled retry, cancellation, and
generation. Mutation IDs are device_id plus local_counter, retries are
idempotent, and delete tombstones prevent stale-device resurrection.

The coordinator MUST reject duplicate enqueue and concurrent drain. A pause,
close, logout, or expiry cancels the current generation, and a late completion
cannot commit. Failed work persists next_retry_at and has a timer/background
wake path; waiting for a future user action is not a retry strategy. Initial
backfill is pausable, restartable, and resumable from a durable cursor.

CloudKit supplies only a one-time latest encrypted Snapshot import into SQLite.
The client atomically merges the Snapshot, immediately and persistently freezes
CloudKit writes before any filtering or Supabase upload, then filters SQLite,
encrypts accepted mutations, and uploads through Supabase. Each macOS/iOS
platform records local-import and cloud-migration markers; overall success
requires both platform marker pairs and recovery conditions. CloudKit is
read-only recovery for 90 days; no dual-write period exists. Deletion after 90
days is a separate explicit authorization concern. Iroh implementation/data
remains but the unified capability is off and this project does not delete or
revive it.

## MCP and visibility

MCP is local-first and must honor the same SQLite privacy and visibility rules.
For every remote await, the operation revalidates session, entitlement, tool
authorization, and item visibility immediately before and after awaiting. A
visibility change returns no payload. MCP audit data contains metadata only and
never query text, clipboard content, OCR text, URLs, file contents, image bytes,
tokens, or keys.

Source-token tests or a static UI test cannot replace real runtime evidence.
The macOS/iOS app must be built, launched, and interacted with using the real
installed target before claiming a security-sensitive path works. Runtime
evidence must include the environment, entitlement state, privacy state, and
the final visible result.

## Deletion and recovery

Cloud deletion is a transactionally observable concern. Removing one item
reuses authenticated `api.push_mutations(operation=delete)`, creates or retains
the durable tombstone first, and then cleans that item's ciphertext, private
Storage objects, semantic document, semantic FTS, vector, and eligible sync
payload. The tombstone is never cleaned and remains until an explicit safe
compaction gate; stale devices cannot resurrect the item. Delete-only cleanup
is allowed with a valid Supabase auth session after subscription/entitlement
expiry, while upsert still requires `cloud_sync`; an expired or invalid JWT is
denied.

The explicit Delete AI index action uses `scope=semantic_index` and the same
worker. Its transaction first disables AI processing and bumps the AI/index
generation, then cancels/marks stale tasks and removes only semantic documents,
FTS, vectors, and query cache. It preserves ciphertext, Storage, account keys,
and BYOK credentials; explicit re-enable is required before rebuild. All-cloud, account, and BYOK credential cleanup use the authenticated Edge
`POST /functions/v1/deletion-request` endpoint and its
`GET /functions/v1/deletion-status?job_id=...` status endpoint. The shared
`CloudDeletionCoordinator` actor owns client request/retry/status;
the single DeletionWorker claims `private.deletion_jobs` with a monotonic
claim epoch, unique lease token, owner heartbeat, and durable wake-up. Every
heartbeat/phase advance must match the job, epoch, token, and unexpired lease;
reclaim mints a new token and stale await/ABA/restart calls fail with
`DELETION_LEASE_LOST`. Worker identity is diagnostic only. It
returns `DELETION_IN_PROGRESS` to recreation/indexing/rebuild/backfill while a
job is nonterminal. All-cloud cleanup first atomically bumps `cloud_generation`,
disables cloud processing, installs reset fences, invalidates old device cursors
and pending pre-generation outbox, and rejects old-generation upsert/backfill
even when an entitlement is active. The old account key remains usable until
ciphertext, Storage, derived data, and sync-payload cleanup is verified; only
then are the account-key and BYOK Vault secrets removed. Only the first-ever
cloud enable may run the automatic full compliant backfill. Re-enable after
all-cloud/account reset establishes only a new key, generation, and enrollment;
it never auto-backfills reset-time local history. Account cleanup
performs the same reset and data-first order, then
deletes the Supabase Auth user last. BYOK cleanup disables/destroys only that
credential. All-cloud/account reset marks every device with a reset fence.
Before push, a reconnecting device must pull the fence/version/challenge,
atomically isolate pre-reset outbox rows and compute the observed floor from all
locally allocated counters, then CAS-ACK the active fence. The server computes
the effective floor as the max of its accepted floor and observed floor, mints
the enrollment generation, and rejects push until that re-enrollment; each
mutation's immutable creation enrollment must match and its counter must exceed
the effective floor. Reset-time local history never auto-backfills. These endpoints require
a valid Supabase auth session and remain
available with expired subscription/entitlement without retrieving or using
any remote secret; an expired or invalid JWT is always denied. Any incomplete cleanup
remains visibly pending and does not pretend data is gone; every cleanup fails
closed and is observable. Re-enable uses only `POST /functions/v1/re-enable`;
`cloud_sync` creates a new account-key version and cloud generation, while
`semantic_index` creates a new indexing generation and active embedding
identity. The request carries expected cloud/indexing generation(s), expected
reset-fence ID, terminal deletion-job ID, and an idempotency key; the server
locks state and rejects a delayed stale request with
`REENABLE_PRECONDITION_FAILED`. A nonterminal deletion job blocks both scopes.

Local deletion remains user-controlled and must not be undone by stale cloud
pulls. Corrupt local or cloud envelopes fail closed. CloudKit recovery imports
only the latest valid encrypted Snapshot and never uses plaintext temporary
files.

## Hard-issue acceptance checklist

| Prior hard issue | Target security contract |
| --- | --- |
| local trial bypass | verified complete-set entitlement only; no local trial flag |
| image OCR/sensitive-scan race | scan/OCR completes or fails closed before upload |
| one StoreKit transaction hides another | recompute all valid transactions |
| retry has no timer wake | durable next_retry_at plus timer/background wake |
| duplicate enqueue/concurrent drain | one actor owner with idempotent mutation IDs |
| pause/close leaves generation alive | cancellation and generation gate block late commit |
| fixed ten-minute JWT crosses expiry | current entitlement check at every Edge/RPC operation |
| MCP await skips revalidation | before-and-after session/visibility/entitlement check |
| custom BYOK HTTP URL leaks | V1 OpenRouter-only Vault flow |
| source-token tests replace app evidence | real macOS/iOS build, launch, interaction, and runtime evidence |
| FTS hidden inside lexical RRF | separate server FTS, server vector, and local lexical lists |
| excluded conflated with failure | independent index_state and user_excluded state |

## Implementation prerequisites

The full schema, RLS/Data API exposure, RPC request/response shapes, private
Vault mapping, and documented Swift signatures are in
SUPABASE_SCHEMA_API_CONTRACT.md. The cross-work-package evidence matrix is in
SUPABASE_ACCEPTANCE_MATRIX.md. Neither document creates cloud resources or
proves implementation.
