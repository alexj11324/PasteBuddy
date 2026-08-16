# ADR-001: Supabase cloud convergence with a local SQLite read source

## Status

Accepted as the WP0 contract freeze. Implementation, migration, and production
provisioning are deliberately out of scope for this ADR.

## Date

2026-08-15

## Decision markers

- **MUST / SHALL** is normative and is a release-blocking contract.
- **Candidate / tentative** is not frozen. It may change only through a
  documented bake-off or a superseding ADR.
- A document contract is not evidence that the corresponding code or hosted
  project exists.

## Context

PasteBuddy has a complete local-first product surface, but the previous cloud
direction made several boundaries unsafe or ambiguous:

- the local semantic index was accidentally treated as the long-term cloud
  architecture;
- a stateless gateway could issue a fixed-ten-minute token and had no durable
  account, entitlement, cursor, or mutation owner;
- CloudKit encryption was described as end-to-end even though a future service
  must be able to recover account data;
- Realtime events, retries, and concurrent drains had no single state owner;
- independent BYOK URLs and provider keys made routing and retention policy
  impossible to prove;
- three-way search fusion did not clearly distinguish server semantic FTS from
  local lexical search;
- source-token/UI tests could pass without proving the real macOS/iOS path.

The product needs offline operation, a durable per-account cloud convergence
point, controlled AI retrieval, and a migration path that does not destroy
existing local history. Clipboard content is high-sensitivity data, so the
system must make the safe path the only path at every boundary.

## Decision

### 1. Ownership and data flow

The client has one **SyncCoordinator actor** as the owner of queue draining,
scheduled retry, cancellation, and generation. SQLite is the only client read
source for UI, offline search, and the pending sync queue. Supabase Postgres is
the authoritative convergence point for logged-in cloud data. It is not a
second UI cache.

Realtime is a revision notification channel only. A reconnect or any
notification MUST cause a cursor pull from the pull_changes RPC; a WebSocket
event MUST NOT be treated as a record payload or data source. A pull response is
committed to SQLite before UI observation or the next local drain.

The flow is: macOS/iOS client -> local SQLite (UI, offline, and outbox read
source) -> single SyncCoordinator actor -> Supabase Postgres (cloud
convergence). Supabase emits a revision-only Realtime notification; reconnects
and notifications return to the coordinator for a cursor pull. Client-filtered
AES-256-GCM ciphertext and separately derived, redacted AI artifacts follow
their respective encrypted or service-visible paths.

The client MUST maintain a durable device_id and monotonic local counter.
Every mutation ID is device_id plus local_counter; a retry of the same mutation
is idempotent. Delete tombstones win over older updates and an old device MUST
NOT resurrect a tombstoned item.

### 2. Security and data classification

Raw clipboard content MUST be filtered on the client before any cloud request.
Content rejected as sensitive MUST never be uploaded. Accepted raw text,
structured values, and image/file bytes MUST be encrypted with AES-256-GCM
before entering Postgres or private Storage. The ciphertext MUST carry an
explicit key version, nonce, and authenticated associated data (AAD).

The recovery key is hosted by the service boundary. This is **server-recoverable
encryption**, not end-to-end encryption. Product, UI, and review copy MUST NOT
call this E2EE or imply that the service cannot recover data.

For an allowed Cloud AI operation, compliant original text or image bytes may be
processed transiently by a multimodal Edge function. It MUST NOT be persisted
as a plaintext request, log, cache, queue item, or database column. The
resulting redacted semantic document, semantic FTS representation, and
pgvector halfvec(1024) embedding are service-visible derived data; they MUST
not be presented as encrypted raw clipboard content.

The account data encryption key is a separate Vault-backed secret from the
BYOK credential. The service creates, authorizes, rotates, and eventually
deletes the AES-256-GCM account key. An authenticated authorized device may
receive actual key material only through
`POST /functions/v1/account-key-delivery` and stores it in Keychain/secure
storage; the service retains its recovery copy. key_version
and rotation_status are required metadata. The BYOK OpenRouter key is never
returned to the client: the client sees only its fingerprint and can test,
replace, or destroy it. A single-item delete reuses
api.push_mutations(operation=delete), creates or retains a durable tombstone,
and cleans only that item's ciphertext, Storage object, semantic document, FTS,
vector, and eligible sync payload. The tombstone is never part of cleanup and
remains until an explicit safe compaction gate. All-cloud/account deletion
additionally cleans the account recovery key and BYOK Vault secret after all
data cleanup is verified. Every cleanup is observable and fail closed.

Only `private.vault_secret_refs.vault_secret_ref` stores an opaque Vault
reference. `api.account_keys` contains key version, fingerprint, rotation, and
delivery metadata only; `api.ai_profiles` contains BYOK fingerprint/status only.
Account-key references are keyed by user, secret kind, and account-key version,
with one reference per version. Rotation creates and activates the new version
while the old version becomes retiring and remains decryptable/recoverable;
only reencryption, required device acknowledgements, and a safe rotation gate
permit revoking/deleting the old reference. BYOK has at most one active
reference per user; replacement switches the active reference atomically, then
destroys the old secret.

### 3. Supabase tenancy and platform constraints

The deployment SHALL use a new, independent PasteBuddy Supabase project in
us-east-1. It MUST NOT reuse a project owned by another product. Free tier is
for Dev/Alpha only; a Pro plan is required before a formal paid launch.

The account limits are 5,000 cloud clipboard items and 250 MB of cloud
attachments per account. Local history has no product-count limit in this
contract. A
no-account local mode MUST remain fully usable, including capture, local
history, and local controls.

New tables and functions MUST have explicit Data API exposure decisions and
explicit grants; no implicit table exposure is allowed. RLS is mandatory on
api user-owned tables. Data API exposed schemas are explicitly api only for
the client-facing function surface; api table CRUD has no anon/authenticated
grant. The client-facing semantic-search boundary is an authenticated Edge
endpoint. `private.match_clipboard` is a restricted database RPC, is not exposed
through the Data API, and has no anon/authenticated EXECUTE grant; only
`service_role` or a dedicated `trusted_edge` role may call it. The
public schema does not contain PasteBuddy business tables or RPCs and remains
unexposed. The private schema MUST not be exposed through the Data API or
Realtime and MUST have no anon/authenticated table grants. This project MUST
NOT pin an extension version in architecture or migration documentation.
Realtime schema/publication changes are out of scope and forbidden for this
migration.

Storage signing is Edge-owned. The Data API allow-list contains no asset
reserve/commit signer RPC: upload reserve and commit use authenticated Edge
endpoints that call private metadata transactions and sign exact private
objects with the Edge Storage service client. Encrypted export returns
attachment metadata only; a separate identity-only Edge endpoint signs a
short-lived exact-object download URL. SQL/private metadata functions never
sign URLs, and Storage bearer URLs are not claimed to be single-use when the
primitive only provides expiry.

Supabase Edge functions use the Supabase Deno-compatible TypeScript runtime
and CLI. Node 22+ and TypeScript 5 are prerequisites only for repository tools,
the legacy gateway, or CI tooling that actually runs on Node and uses
supabase-js. If management tooling later calls Supabase Management OAuth
/v1/oauth/token, any successful 2xx response is accepted; this is not a
StoreKit/Auth entitlement rule.

### 4. Authentication and commercial authority

Apple, Google, and Magic Link authentication SHALL resolve to one Supabase
user_id. StoreKit purchases MUST set appAccountToken to the Supabase UUID. An
Edge verifier MUST validate signed transactions and persist a normalized
entitlement record, never a raw signed payload.

Every transaction update or restore MUST recompute the complete set of valid
transactions. One expired or revoked transaction MUST NOT overwrite another
valid transaction. There is no local simulated trial. A local flag, cached
semantic record, or API key MUST never prove entitlement.

Entitlements are orthogonal. An active Cloud subscription grants `cloud_sync`
and `platform_ai`; an active BYOK Annual grants `cloud_sync` and `byok_ai` but
does not grant `platform_ai`. `cloud_sync` permits encrypted cloud writes,
pulls, quota, and attachment operations. `platform_ai` permits platform
OpenRouter AI, while `byok_ai` unlocks use of the user-supplied OpenRouter
credential. Local mode requires no account and never proves a remote capability.
The raw BYOK key MUST be stored in Supabase Vault and the client may see only a
non-secret fingerprint. V1 MUST NOT accept a custom BYOK URL, provider host, or
arbitrary OpenAI-compatible endpoint.

Every RPC and Edge endpoint MUST check its operation-specific boundary: sync
push/upsert RPCs require `cloud_sync`; owner-scoped `pull_changes` and cursor
ACK require only a valid identity session plus enabled-state, generation,
reset-fence, and RLS checks; semantic-search Edge requests require
`platform_ai` or `byok_ai`; and remote account-key retrieval for a new device
requires `cloud_sync`. After
every provider await, the Edge revalidates session and capability. Expiry,
revocation, suspension, or failed refresh immediately disables all three remote
capabilities and all remote Vault secret retrieval/use. A cached account key
continues to support local decryption, but a new device cannot recover it from
Vault until `cloud_sync` returns. Explicit cloud deletion or Vault-secret
destruction remains an allowed cleanup operation and is not secret use.
A Supabase identity JWT remains valid under its normal session lifecycle after
commercial expiry and permits owner-scoped login, encrypted `pull_changes`,
cursor ACK, paginated encrypted export, deletion, and cleanup, subject to
enabled-state, generation, reset-fence, and RLS checks. Export may return only
the user's encrypted envelopes and attachment IDs/metadata; a separate
identity-only Edge signer issues any short-lived exact-object download URL. It
never returns plaintext or Vault key material. The identity JWT does not
grant any remote capability. Operation assertions are short-lived and bounded
by the named entitlement check; they are revalidated before and after every
remote await.

Initial provisioning is a separate authenticated Edge contract,
`POST /functions/v1/initial-enable`, with `{ idempotency_key, scope,
device_id, platform, device_signing_public_key,
device_key_agreement_public_key, challenge_id, proof_signature,
request_context_hash }`. It is allowed only for a never-provisioned scope and
its named capability. The Edge may precheck the signature, but under the same
profile/device lock its authoritative transaction checks the unbound-or-
same-user device ID, fresh-unused challenge CAS, cross-user rule, canonical
proof/context, and consumes the challenge. Cloud scope then bind-if-absent
creates the initiating `api.devices` row with two purpose-separated public keys;
semantic scope requires an existing same-user non-revoked device and never
replaces its keys. Cloud scope
creates the initial Vault-backed account-key version, cloud generation, and
server-minted initiating-device enrollment; semantic scope creates the initial
indexing generation and active identity. No key material is returned, and the
initial compliant backfill starts only after bootstrap success plus
`POST /functions/v1/account-key-delivery`. A same-user proof/idempotency retry
is idempotent; a different key or cross-user UUID fails closed. Later devices
use authenticated `POST /functions/v1/register-device` with active
`cloud_sync`, platform, two public keys, and a fresh signing-key proof; it is
not a Data API RPC. Semantic initial-enable requires an existing same-user
non-revoked device; cloud bootstrap is the only device-creation path.
Reset-required devices must use fence ACK, not registration, to rejoin.

Account-key delivery is the only remote key-material boundary. It requires a
valid identity, active `cloud_sync`, same-user/non-revoked device, current
enrollment/reset ACK, and a `purpose=key_delivery` proof from the separate
signing key; the registered agreement key wraps the envelope. The exact proof
wire uses RFC4122 UUID16, purpose/scope/platform bytes, X9.63 P-256 points
(65 bytes), base64url-no-pad JSON, and raw IEEE-P1363 ECDSA `r32||s32` (64
bytes). Its outer message is
`ASCII("PasteBuddyDeviceProof/v1")||0x00||userUUID16||deviceUUID16||purposeU8||challengeUUID16||SHA256(rawNonce)||requestContextHash32`.
Register context is
`ASCII("PasteBuddyRegisterContext/v1")||0x00||scopeU8||platformU8||signingX96365||agreementX96365||idempotencyUUID16`;
key-delivery context is
`ASCII("PasteBuddyKeyDeliveryContext/v1")||0x00||enrollmentUUID16||u32be(keyVersionUTF8ByteCount)||keyVersionUTF8||idempotencyUUID16`.
Key versions are ASCII `[A-Za-z0-9._-]{1,64}` and all malformed lengths,
points, encodings, contexts, or signatures fail closed.

The v1 envelope uses agreement-key ECDH with the 32-byte big-endian X
coordinate, left-padded as needed; invalid points and all-zero secrets fail.
AAD is
`ASCII("PasteBuddyAccountKeyEnvelope/v1")||0x00||userUUID16||deviceUUID16||enrollmentUUID16||u32be(keyVersionByteCount)||keyVersionASCII||challengeUUID16||deliveryUUID16`.
HKDF-SHA256 is IKM=ECDH32, salt
`SHA256(ASCII("PasteBuddyKeyWrapSalt/v1")||0x00||deliveryUUID16||challengeUUID16)`,
info=AAD, L=32. Plaintext is 32 bytes; AES-256-GCM uses random nonce 12,
tag 16, ciphertext 32; expiry is RFC3339 UTC metadata only. CryptoKit
`x963Representation`/SharedSecret and Deno WebCrypto raw-point/deriveBits256
must cross-verify fixed non-secret WP2 vectors, including explicit DER-to-raw
ECDSA conversion when required.

### 5. Synchronization contract

SyncCoordinator SHALL own enqueue, drain, scheduled retry, cancellation, and
generation. It MUST prevent duplicate enqueue and concurrent drains, and a
pause/close MUST cancel the active generation so a late task cannot commit.
Failed work MUST have a durable next_retry_at and a timer/background wake path;
a retry that waits only for a future user action is invalid.

Mutation order is determined by server revision and tombstone precedence, not
arrival order. Attachment flow is Edge reserve (private metadata transaction,
then exact-object Storage signing) -> upload ciphertext -> Edge commit
(owner/path/size/hash verification, then private metadata transaction).
Encrypted export returns attachment metadata only; identity-only download
signing is a separate short-TTL Edge endpoint. Uncommitted objects older than
24 hours are orphan-cleanup candidates.
Reaching quota stops new cloud uploads only; it MUST NOT delete local data or
existing cloud data. First backfill MUST be pausable, restartable, and
resumable from a durable cursor/checkpoint.

Deletion has one owner: the single `CloudDeletionCoordinator` actor requests
jobs from the sole DeletionWorker, which claims `private.deletion_jobs` with an
atomic owner/lease/heartbeat, a monotonic `claim_epoch`, and a unique
`lease_token`. Heartbeat and phase advance must match the job, epoch, token,
and unexpired lease; lease expiry permits one recovery claim with a new token.
No Settings, BYOK, or account feature may instantiate another owner.
Single-item deletion is an authenticated delete-only
api.push_mutations(operation=delete) path that creates/retains the durable
tombstone before cleaning payload and derived data; it is allowed after expiry,
while upsert still requires `cloud_sync`. A valid Supabase auth session is
still required after subscription/entitlement expiry; an expired or invalid
JWT is denied. All-cloud, account, semantic-index, and BYOK credential cleanup
use the authenticated Edge endpoints
`POST /functions/v1/deletion-request` and
`GET /functions/v1/deletion-status?job_id=...` defined in the schema contract.
They are idempotent, status-visible to Settings, and do not require
`cloud_sync` after expiry. Semantic-index cleanup preserves ciphertext,
Storage, account keys, and BYOK credentials. The transaction disables AI
processing and bumps the AI generation before cancelling tasks/deleting
artifacts; explicit re-enable is required before rebuild.
All-cloud reset atomically bumps `cloud_generation`, disables cloud processing,
installs per-device reset fences, invalidates old cursors/outboxes, and rejects
old-generation upserts/backfill even when entitlement is active. The old
account key remains available only for cleanup and recovery of the existing
ciphertext until ciphertext, Storage, derived data, and eligible sync payload
cleanup is verified; only then is that key (and any account-scoped Vault
secret) deleted. Before any resumed device push, it requires a reset-fence
pull, local pre-reset outbox isolation, counter-floor recording, and fence
ACK/re-enrollment; only post-floor new mutation identities are accepted.
Reset-time local history never auto-backfills.
`POST /functions/v1/re-enable` is the only re-enable endpoint: `cloud_sync`
requires active cloud_sync and creates a new account-key version plus cloud
generation; `semantic_index` requires platform_ai or byok_ai and creates a new
indexing generation plus active embedding identity. Its request carries the
expected cloud/indexing generation(s), expected reset-fence ID, terminal
deletion-job ID, and idempotency key. The server locks state and rejects a
stale delayed request with `REENABLE_PRECONDITION_FAILED` when the terminal
job, deletion intent, fence, or generation no longer matches. Both are
idempotent, status-visible operations and fail closed while deletion is
nonterminal.
Account cleanup is data-first, then Vault secrets, then Supabase Auth user
deletion last. A
nonterminal job blocks recreation, indexing, rebuild, and backfill with
`DELETION_IN_PROGRESS`.

### 6. AI retrieval contract

The only automatic precondition for indexing is the concrete AI capability
(`platform_ai` or `byok_ai`) and an accepted client privacy decision. Cloud
upload of the resulting encrypted artifacts also requires `cloud_sync`. The
client performs sensitive scanning before image OCR/semantic upload can race;
image OCR and sensitive scanning MUST complete (or fail closed) before any
bytes are sent.

Platform and BYOK AI requests MUST use OpenRouter with provider.zdr=true and
data_collection=deny. A provider/embedding allowlist probe MUST verify both
flags for the selected route; if no endpoint can prove zero retention, the
request MUST fail closed and BYOK MUST NOT bypass the policy. The platform and
BYOK embedding dimensions are both fixed at 1024. Each account has exactly one active
embedding identity. Changing model, tokenizer, or identity marks old vectors
stale and schedules a full, resumable rebuild.

Every provider-await return and semantic-document/vector write is guarded by a
database-atomic check of user/item ownership, enabled AI processing, active
embedding identity, and `indexing_generation`; stale results fail with
`AI_GENERATION_STALE` and cannot commit. Semantic-index deletion disables and
bumps the generation before cancelling tasks or deleting derived artifacts.

Qwen3 Embedding is the default embedding candidate. gte-small is not a
candidate for this architecture. The model itself is not permanently locked
until the bake-off passes the thresholds below.

The UI semantic search is a user-clicked, one-shot sparkle action. Editing input
or pressing Enter MUST NOT trigger a remote AI search. The client calls only an
authenticated Edge endpoint with `query`, `filters`, and `limit`. The Edge
revalidates session and `platform_ai`/`byok_ai`, keeps the query transient,
calls the selected OpenRouter route, and revalidates again after every provider
await. The trusted Edge creates an internal request ID and canonical request
hash over the verified user, active identity, indexing generation, semantic
query, filters, and limit (not raw clipboard content), then creates a
short-lived, single-use `private.operation_capability_assertions` row bound to
both values. It invokes restricted `private.match_clipboard` through the
trusted service path with `p_user_id`, `assertion_id`, `p_request_id`,
`p_request_hash`, `query_embedding halfvec(1024)`, `semantic_query`, `filters`,
and `limit`; the RPC consumes the assertion in the same transaction, never
calls a provider, and hard-scopes vector/FTS queries to the Edge-verified user.
`service_role` alone is not an AI capability and the assertion is never
client-visible.

The client combines three independent rank lists with RRF:

1. server vector matches;
2. server semantic FTS matches;
3. local lexical matches from SQLite.

FTS MUST NOT be folded into the local lexical list. The response models
ready=0, offline, partial index, failed, and no relevant result as distinct
states. excluded is a separate user exclusion state and MUST NOT be reused for
recoverable failure or indexing-in-progress. The query path is client
sensitive-query gate -> authenticated Edge semantic-search endpoint -> trusted
private.match_clipboard RPC -> independent server vector and semantic FTS rank lists
-> client RRF with local lexical. The client never supplies a halfvec query
embedding. MCP is an explicit tool invocation, not a sparkle click, but it
follows the same retrieval contract and MUST re-check authorization and item
visibility immediately before and after every remote await; an earlier
authorization result is not sufficient.

### 7. CloudKit retirement

CloudKit is a one-time recovery source, not a second sync authority. The
migration SHALL read and atomically merge the latest encrypted Snapshot into
SQLite, then immediately and persistently freeze CloudKit writes before any
Supabase upload. Only after that freeze does the client filter restored SQLite
data, encrypt accepted mutations, and upload through Supabase. macOS and iOS
each record local-import and cloud-migration markers; the overall migration is
successful only after both platform marker pairs satisfy recovery conditions.
There is no dual-write interval.

CloudKit recovery remains read-only for 90 days. There is no dual-write period.
Deletion after 90 days is a separate, explicit user-authorized concern and is
not hidden inside migration. Existing Iroh implementation/configuration is
preserved, but the unified PasteBuddyFeatureAvailability.irohClipboardSync
capability remains off; this project does not delete Iroh.

### 8. Bake-off and evidence gate

The architecture freezes evaluation gates, not an unverified model choice. A
candidate is eligible only if all are true:

- strict JSON validity is at least 99.5%;
- sensitive-content leakage is exactly 0;
- Recall@5 is at least 0.85;
- nDCG@5 is at least 0.80.

After eligibility, choose the candidate with the lowest cost per qualified
request. The bake-off MUST record dataset version, policy version, model and
provider configuration, retention proof, latency, cost, and failure counts.
No model may be selected from a source-token test alone.

## Alternatives considered and rejected

| Alternative | Decision |
| --- | --- |
| Treat the local SQLite semantic index as the cloud target | Rejected: SQLite remains the client read source, but logged-in cloud convergence needs durable account, cursor, quota, and deletion semantics. |
| Keep a stateless gateway with a fixed ten-minute JWT | Rejected: it has no authoritative entitlement, identity-session, or Vault boundary; operation capability assertions must be checked per operation. |
| Describe AES-GCM plus server recovery as E2EE | Rejected: server recovery is explicitly incompatible with the E2EE claim. |
| Accept arbitrary BYOK OpenAI-compatible URLs | Rejected: URL/provider routing can exfiltrate keys or content; V1 is OpenRouter-only. |
| Let Realtime events carry the data | Rejected: notifications can be dropped, reordered, or duplicated; cursor pull is the source of truth. |
| Use separate embedding dimensions per provider | Rejected: one halfvec(1024) shape and one active identity keep ranking and rebuild semantics deterministic. |
| Write CloudKit and Supabase in parallel | Rejected: dual authorities create resurrection and conflict ambiguity; CloudKit is read-only recovery for 90 days. |
| Search as the user types or on Enter | Rejected: explicit sparkle click is the privacy, cost, and latency boundary. |
| Merge semantic FTS into local lexical RRF | Rejected: three independent rank lists are required for diagnosable retrieval. |

## Migration order

1. **WP0 (this ADR):** freeze contracts, schema/API boundaries, privacy
   language, and evidence matrix. No code or cloud resources.
2. **WP1:** create the independent Supabase project, schema, RLS, grants,
   Data API allow-list, private Vault/task boundary, and revision channel.
3. **WP2:** implement Supabase auth, transaction verification, complete-set
   entitlement recomputation, account-key authorization, BYOK Vault fingerprint
   flow, and expiry locks.
4. **WP3:** implement client AES-256-GCM envelopes, SQLite mutation outbox,
   the single SyncCoordinator, cursor pull/push, and attachment lifecycle.
5. **WP4:** implement Cloud AI/BYOK, transient compliant Edge AI, ZDR policy,
   semantic documents, pgvector halfvec(1024), one active embedding identity,
   resumable indexing, three-list RRF, and the model bake-off.
6. **WP5:** implement Settings UI/state, the CloudKit latest-snapshot import,
   immediate write freeze, macOS/iOS local+cloud migration markers, 90-day
   read-only recovery, and real UI/migration runtime acceptance.
7. **WP6:** perform production deployment, scale/release checks, and final
   macOS/iOS release-gate verification after WP4/WP5 evidence is attached.

Each step requires its own focused, reversible checkpoint. A passing document
review, source scan, or unit test does not establish real-runtime acceptance.

## Consequences

Positive consequences:

- offline/local behavior has a clear owner and remains complete without an
  account;
- server recovery, deletion, retention, and entitlement semantics are explicit;
- Realtime, retries, attachments, and AI indexing have observable failure
  boundaries;
- the model/provider bake-off is measurable without pretending a candidate is
  final.

Costs and risks:

- the client must maintain an encrypted outbox and durable cursor/checkpoint;
- Supabase RLS, Vault, Edge, Storage, and revision behavior require live
  staging evidence;
- CloudKit retirement and 90-day recovery need careful user-facing migration
  UX;
- model quality and cost remain open until the bake-off passes.

## Non-goals

V1 targets macOS and iOS. Android and Web are protocol-frozen only. This ADR
does not create a Supabase project, deploy migrations, change Realtime schema,
modify Swift/SQL/TypeScript, delete CloudKit or Iroh code, or claim that the
migration is implemented.
