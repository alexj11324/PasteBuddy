# Supabase schema, RPC, Storage, and Swift protocol contract

## Status and scope

This is the WP0 schema/API contract freeze for the Supabase migration. It is a
document contract only: no SQL migration, Edge function, Swift implementation,
Storage bucket, Vault secret, or Supabase project is created by this document.

**MUST / SHALL** statements are normative. **Candidate / tentative** statements
are bake-off inputs and must not be treated as implementation commitments.
Android and Web consume this protocol only; V1 runtime implementation is
macOS+iOS.

The client-side invariant is strict: local SQLite is the only read source for
UI, offline behavior, and the sync queue. Supabase is the logged-in account's
cloud convergence authority. Realtime emits revision notifications only;
reconnects and notifications always invoke cursor pull.

## Security and boundary vocabulary

- Raw clipboard text, images, files, OCR output, and other sensitive content
  are client-filtered before any remote request. A blocked item is never
  uploaded.
- Accepted raw content is encrypted on-device with AES-256-GCM before
  Postgres/Storage upload. Envelopes include ciphertext, nonce, AAD, and key
  version. The service holds recovery material, so the product term is
  **server-recoverable encryption**, never E2EE.
- A compliant original may exist only transiently inside an authorized Edge
  AI request. It must not enter a database, queue, log, cache, or Storage
  object. Redacted semantic documents, semantic FTS, and vectors are visible
  to the service and are not raw content.
- Platform and BYOK Cloud AI use only the OpenRouter allowlist with
  provider.zdr=true and data_collection=deny. A provider/capability probe MUST
  verify both flags before either route uses a key; missing or unverifiable
  zero retention is fail-closed and a BYOK key cannot bypass this policy.
- V1 BYOK is OpenRouter-only. The raw key is stored in Supabase Vault; the
  client receives only an opaque key fingerprint. Custom provider URLs are not
  part of this contract.
- Platform and BYOK embeddings use exactly 1024 dimensions and the database
  type is pgvector halfvec(1024). One account has one active embedding
  identity.

## Schemas, grants, RLS, and Data API exposure

The deployment SHALL be a new independent PasteBuddy Supabase project in
us-east-1. It MUST NOT reuse another product's project. New tables, functions,
Storage buckets, and Realtime behavior require explicit exposure decisions.
No extension version is pinned here, and this migration MUST NOT modify the
Realtime schema or publication.

| Boundary | RLS | Data API | anon grants | authenticated grants | Service/internal access |
| --- | --- | --- | --- | --- | --- |
| api tables listed below | enabled and deny-by-default | direct table CRUD: explicitly **not exposed** in V1 | none | no table SELECT/INSERT/UPDATE/DELETE; RPC only | constrained definer functions and service role |
| client api RPC allow-list | function-level auth checks | explicitly exposed: api.push_mutations, api.pull_changes, api.ack_revision, api.export_encrypted, api.pull_reset_fence, api.ack_reset_fence | no EXECUTE | EXECUTE only after a valid Supabase JWT plus the operation-specific owner/capability check; identity-only read/export/fence/cleanup paths do not require commercial entitlement | internal jobs may call through a separate service path |
| private.match_clipboard restricted RPC | fixed search_path and trusted-context checks | private schema never exposed through the Data API | no EXECUTE | no EXECUTE | service_role or dedicated trusted_edge role only; Edge supplies verified user context and capability |
| private schema tables | enabled where supported | never exposed | none | none | service role or locked-down SECURITY DEFINER only |
| private Storage bucket | object owner checks | no public URLs/listing | none | signed upload/download issued only by reserve/authorized read path | cleanup/verification worker |
| Realtime revision channel | not a table read path | no row payload exposure | none | authenticated revision notification only | publisher emits revision metadata |

The Data API exposed schema list SHALL be explicitly configured to api only for
PasteBuddy's user-facing function surface. The public schema MUST NOT contain
PasteBuddy business tables or RPCs and remains unexposed. The private schema
is never exposed. All api user-owned tables SHALL have a user_id owner column,
RLS enabled, and policies tied to auth.uid(). SECURITY DEFINER RPCs SHALL use a
fixed search path and re-check the caller's user_id; a JWT claim alone is not
an entitlement. The client-facing semantic-search boundary is an authenticated
Supabase Edge endpoint, not a direct call to private.match_clipboard. The private
schema MUST contain no clipboard plaintext, unwrapped encryption key, or raw
BYOK key.

## Orthogonal capability contract

Entitlement rows are normalized into independent capabilities; no single
capability authorizes unrelated cloud operations, and no rule treats any
active subscription as permission for every operation:

| Capability | Granted by | Permitted operations |
| --- | --- | --- |
| `cloud_sync` | active Cloud subscription **or** active BYOK Annual | encrypted cloud sync, quota, cursor pull, and attachment upload/commit |
| `platform_ai` | active Cloud subscription only | platform OpenRouter AI, semantic indexing/search using the platform route |
| `byok_ai` | active BYOK Annual only | AI using the user-supplied OpenRouter Vault credential, including semantic indexing/search using the BYOK route |
| `local` | no account required | local capture/history/search; never proof of a remote capability |

Every client-facing RPC and Edge endpoint SHALL name and check its required
identity/capability boundary. `pull_changes`, `ack_revision`, `export_encrypted`,
`pull_reset_fence`, and `ack_reset_fence` require only a valid Supabase identity
session plus owner/RLS and current enabled generation/fence checks where
applicable; they do not require commercial entitlement. Push upserts,
the authenticated Edge asset-upload reserve/commit endpoints require
`cloud_sync`; their private metadata transactions are never Data API exposed.
An authenticated delete-only `push_mutations` cleanup is the explicit expiry
exception. The
authenticated semantic-search Edge endpoint requires `platform_ai` or
`byok_ai`, selects the corresponding provider route, and revalidates the
session and capability after every provider await. The trusted
`private.match_clipboard` RPC accepts only an internal assertion for one of those
AI capabilities; it never calls an AI provider itself. BYOK Vault retrieval or
use requires `byok_ai`. Remote account-key retrieval for a new device requires
`cloud_sync` and an enabled cloud-processing state.

When entitlement expires, is revoked, suspended, or cannot be refreshed, all
three remote capabilities become false: cloud writes, platform AI, BYOK AI,
and every remote Vault secret retrieval/use MUST stop immediately. A device
that already has the account data key in Keychain/secure storage may continue
local decryption, but a new device MUST NOT recover that key from Vault until
`cloud_sync` is active again. Explicit authenticated deletion of cloud data or
destruction of a Vault secret remains an allowed cleanup operation after
expiry; it is not retrieval or use of the secret and does not restore a
capability. An all-cloud reset first disables cloud processing, bumps the
generation, installs reset fences, and blocks writes. The old account key
remains usable until ciphertext/Storage/derived/sync-payload cleanup is
verified, then the key and BYOK secret are deleted. Re-enable is explicit and
creates a new account key, generation, and enrollment; it never auto-backfills
reset-time local history.

## Initial enable and device enrollment

Initial provisioning is distinct from post-deletion re-enable. The
authenticated Edge endpoint `POST /functions/v1/initial-enable` is the only
bootstrap boundary. Its request is:

    {
      idempotency_key: UUID (RFC4122),
      scope: cloud_sync | semantic_index,
      device_id: UUID,
      platform: macOS | iOS,
      device_signing_public_key: base64url-no-pad(X9.63 P-256 ECDSA key, 65 bytes),
      device_key_agreement_public_key: base64url-no-pad(X9.63 P-256 ECDH key, 65 bytes),
      challenge_id: UUID,
      proof_signature: base64url-no-pad(IEEE-P1363 ECDSA signature, 64 bytes),
      request_context_hash: base64url-no-pad(SHA-256 digest, 32 bytes)
    }

All UUIDs in proof requests are RFC4122/network-order 16 raw bytes when
encoded into a proof. JSON binary fields use base64url without padding.
`idempotency_key` is itself an RFC4122 UUID; arbitrary strings are rejected.
Both public keys must decode to exactly the ANSI X9.63 uncompressed P-256
form `0x04 || X32 || Y32`, and the point must be on-curve and non-infinity.
Their fingerprints are base64url-no-pad(SHA-256(the 65 decoded bytes)).

It requires a valid Supabase identity JWT, an unbound-or-same-user
`device_id`, and the scope capability: `cloud_sync` for `scope=cloud_sync`, or
`platform_ai`/`byok_ai` for `scope=semantic_index`. For `semantic_index`, a
same-user non-revoked device must already exist; a device is created first by
the cloud bootstrap, otherwise the request fails with
`DEVICE_REGISTRATION_REQUIRED`. The Edge may perform a non-authoritative
cryptographic precheck, but the authoritative transaction locks the relevant
profile/device state and then loads the challenge, checks its fresh-unused
CAS and cross-user UUID rule, recomputes the nonce/context hashes, verifies
the ECDSA proof, consumes the challenge, and creates the bootstrap row under
the same lock. For `scope=cloud_sync`, bind-if-absent creates the complete
`api.devices` row and the transaction server-mints the initiating-device
enrollment. For `scope=semantic_index`, the transaction requires the existing
same-user non-revoked device and does not create or replace its device keys. A
same-user retry with the same proof/idempotency is idempotent; a cross-user
UUID or different key fails closed. The operation is permitted only when that
scope has never been provisioned. Cloud bootstrap creates the initial
account-data-key Vault version, initial `cloud_generation`, and enables cloud
processing. Semantic bootstrap creates the initial `ai_index_generation` and
active embedding identity; old or absent vectors are not mixed into the new
identity. The response is:

    {
      operation_id: UUID,
      status: accepted | succeeded | duplicate,
      scope: cloud_sync | semantic_index,
      cloud_generation: UUID | null,
      account_key_version: String | null,
      enrollment_generation: UUID | null,
      indexing_generation: UUID | null,
      active_embedding_identity: String | null
    }

No key material is returned. The authorized device obtains the account key
through `POST /functions/v1/account-key-delivery`. Only after bootstrap
succeeds and that device has the key does `SyncCoordinator` start the initial full
compliant backfill; the backfill remains pausable, restartable, and resumable.
Repeating the same idempotency key returns the same operation/status. A
different key after the scope is initialized fails closed with
`BOOTSTRAP_ALREADY_INITIALIZED`. Status is available from
`GET /functions/v1/initial-enable-status?operation_id=...`, which returns the
same non-secret metadata and never key material.

Post-deletion `POST /functions/v1/re-enable` remains the only re-enable
boundary after a terminal deletion job and requires its non-null
`terminal_deletion_job_id`; it cannot substitute for initial bootstrap.

After bootstrap, a later device uses the authenticated Edge endpoint
`POST /functions/v1/register-device`:

    {
      device_id: UUID,
      platform: macOS | iOS,
      scope: cloud_sync,
      device_signing_public_key: base64url-no-pad(X9.63 P-256 ECDSA key, 65 bytes),
      device_key_agreement_public_key: base64url-no-pad(X9.63 P-256 ECDH key, 65 bytes),
      challenge_id: UUID,
      proof_signature: base64url-no-pad(IEEE-P1363 ECDSA signature, 64 bytes),
      request_context_hash: base64url-no-pad(SHA-256 digest, 32 bytes),
      idempotency_key: UUID (RFC4122)
    }

It requires a valid identity JWT and active `cloud_sync`, verifies a fresh
single-use `purpose=register` challenge and device-held signing-key proof,
binds the device to `auth.uid()` through the authoritative private metadata
transaction, and
server-mints the device enrollment generation. It returns
`{ device_id, cloud_generation, enrollment_generation, reset_required }`.
An expired account cannot register a new device or retrieve an account key.
A device in reset-required state must use `pull_reset_fence` and
`ack_reset_fence`; registration never bypasses the reset fence. This endpoint
is not a Data API RPC and never accepts a client-supplied enrollment generation.

### Device proof and account-key delivery Edge contracts

`POST /functions/v1/device-proof-challenge` is the common authenticated
challenge boundary for device registration and key delivery. Request:

    {
      device_id: UUID,
      purpose: register | key_delivery
    }

The Edge binds the challenge to `auth.uid()`, `device_id`, and `purpose` in
the challenge transaction, returns
`{ challenge_id, nonce, expires_at, purpose, device_id }`, and stores only a
nonce digest in `private.device_proof_challenges`. The challenge is
short-lived and single-use. A register challenge may be issued for an
unbound-or-same-user device ID; a key-delivery challenge requires an existing
same-user, non-revoked device. Challenge issuance never grants cloud, AI, or
Vault capability.

The canonical proof is byte-exact and domain-separated. Every UUID below is
its RFC4122/network-order 16 raw bytes. The one-byte enums are
`purpose: register=0x01, key_delivery=0x02`, `scope: cloud_sync=0x01,
semantic_index=0x02`, and `platform: macOS=0x01, iOS=0x02`. The client computes
`nonce_digest = SHA-256(raw nonce)` and signs this exact outer message:

    ASCII("PasteBuddyDeviceProof/v1") || 0x00 ||
    userUUID16 || deviceUUID16 || purposeU8 || challengeUUID16 ||
    nonceDigest32 || requestContextHash32

For `purpose=register`, the exact context bytes are:

    ASCII("PasteBuddyRegisterContext/v1") || 0x00 || scopeU8 || platformU8 ||
    signingX96365 || agreementX96365 || idempotencyUUID16

`requestContextHash = SHA-256(registerContextBytes)`. For
`purpose=key_delivery`, the exact context bytes are:

    ASCII("PasteBuddyKeyDeliveryContext/v1") || 0x00 ||
    enrollmentUUID16 || u32be(keyVersionUTF8ByteCount) || keyVersionUTF8 ||
    idempotencyUUID16

`requestContextHash = SHA-256(keyDeliveryContextBytes)`, and
`key_version` is ASCII matching `[A-Za-z0-9._-]{1,64}`. Both public keys are
exactly ANSI X9.63 uncompressed 65 bytes (`0x04 || X32 || Y32`), on-curve and
non-infinity; each fingerprint is
`base64url_no_padding(SHA-256(x963_65))`. The signature is ECDSA
P-256/SHA-256 in IEEE-P1363 raw form exactly 64 bytes (`r32 || s32`), not DER.
All JSON binary fields use base64url without padding. Any wrong length,
base64url encoding, point encoding, point validity, UUID encoding, enum byte,
key-version encoding, context hash, nonce digest, or signature encoding fails
closed. The server reconstructs these bytes from the stored nonce digest and
request fields inside the locked transaction and rejects any mismatch.

`POST /functions/v1/account-key-delivery` is the only remote account-key
material boundary. Request:

    {
      device_id: UUID,
      enrollment_generation: UUID,
      requested_key_version: ASCII [A-Za-z0-9._-]{1,64},
      challenge_id: UUID,
      proof_signature: base64url-no-pad(IEEE-P1363 ECDSA signature, 64 bytes),
      request_context_hash: base64url-no-pad(SHA-256 digest, 32 bytes),
      idempotency_key: UUID (RFC4122)
    }

The Edge requires a valid identity JWT, active `cloud_sync`, same-user
non-revoked device state, current enrollment/reset-fence ACK, an active or
authorized `retiring` key version, and a fresh single-use
`purpose=key_delivery` challenge verified with the registered signing public
key. The challenge, proof, enrollment, key-version, context hash, and
idempotency checks occur under the account/device lock. A revoked key version
is never delivered. The Edge alone reads the account recovery key from Vault
and derives a device-bound envelope using the registered
`device_key_agreement_public_key`, ephemeral P-256 ECDH, HKDF-SHA256, and
AES-256-GCM. Context and AAD bind user, device, enrollment generation, key
version, challenge, and delivery ID. Response:

    {
      delivery_id: UUID,
      key_version: ASCII [A-Za-z0-9._-]{1,64},
      ephemeral_public_key: base64url-no-pad(X9.63 P-256 ECDH key, 65 bytes),
      nonce: base64url-no-pad(12 random bytes),
      ciphertext: base64url-no-pad(32 bytes),
      tag: base64url-no-pad(16 bytes),
      aad: base64url-no-pad(exact AAD bytes),
      expires_at: RFC3339 UTC timestamp
    }

The response has `Cache-Control: no-store`; the original account key is never
present in HTTP, logs, the delivery ledger, or remote persistence outside
Vault. The in-memory delivery envelope, URL, nonce, and signature are not
logged or persisted. A
repeated idempotency key is accepted only with a fresh valid challenge and
proof; the delivery ledger returns the same durable operation identity while
the Edge creates a fresh non-persisted envelope. Replays, wrong devices,
expired/reused challenges, old enrollment, missing reset ACK, revoked key
versions, entitlement expiry, or key-version mismatch fail closed. The
client decrypts the envelope only in memory and writes the key to Keychain or
secure storage. Secure Enclave is preferred; when unavailable, separate
Keychain-protected signing and key-agreement private keys are allowed. The
device holds both private keys; the service stores only their public keys and
fingerprints.

The account-key envelope v1 bytes are interoperable between Swift CryptoKit
and Supabase Edge Deno WebCrypto. The ephemeral key is the same valid X9.63
65-byte P-256 point. ECDH produces exactly the 32-byte big-endian X coordinate
(`deriveBits(..., 256)` on WebCrypto), left-padded with zero bytes when
necessary; invalid points and an all-zero shared secret fail closed. The exact
AAD is:

    ASCII("PasteBuddyAccountKeyEnvelope/v1") || 0x00 ||
    userUUID16 || deviceUUID16 || enrollmentUUID16 ||
    u32be(keyVersionASCIIByteCount) || keyVersionASCII ||
    challengeUUID16 || deliveryUUID16

HKDF-SHA256 uses `IKM=ECDH32`,
`salt=SHA-256(ASCII("PasteBuddyKeyWrapSalt/v1") || 0x00 ||
deliveryUUID16 || challengeUUID16)`, `info=AAD`, and `L=32`. The plaintext
account key is exactly 32 bytes. AES-256-GCM uses a random 12-byte nonce, a
16-byte tag, and therefore a 32-byte ciphertext. `expires_at` is RFC3339 UTC
metadata only and is not included in the cryptographic input. Decryption must
rebuild the exact AAD and HKDF inputs and constant-time verify the tag; any
wrong length, base64url encoding, point, shared secret, AAD, HKDF input, or
tag fails closed.

CryptoKit uses `x963Representation`, raw IEEE-P1363 ECDSA signatures, and the
32-byte `SharedSecret` output. Deno WebCrypto imports the raw X9.63 P-256
point and uses 256-bit `deriveBits`; if a runtime returns DER ECDSA signatures,
it must explicitly convert DER to raw `r32 || s32` before verification. WP2
must run fixed non-secret cross-runtime vectors covering proof and envelope
bytes, point validation, tag failure, and leading-zero X coordinates. WP0
defines no secret fixture or key material.

## api relational model

The following is the minimum frozen model. Field names and enum meanings are
contractual; physical indexes and non-observable implementation details remain
open to WP1.

| Table | Required fields and invariants | Data classification |
| --- | --- | --- |
| api.profiles | id = auth.users.id; created_at; updated_at; account_status; deletion_requested_at; cloud_generation; cloud_processing_enabled; cloud_processing_state; reset_fence_id; reset_fence_generation | account, cloud-generation, and reset-fence authority; no clipboard payload |
| api.devices | id; user_id; platform (macOS/iOS); device_signing_public_key; signing_key_algorithm = P-256 ECDSA/SHA-256; signing_key_fingerprint; device_key_agreement_public_key; key_agreement_algorithm = P-256 ECDH; key_agreement_key_fingerprint; local_counter; last_pull_revision; cloud_generation; pending_outbox_generation; reset_fence_id; reset_required; local_counter_floor; enrollment_generation; reset_acknowledged_at; last_seen_at; revoked_at; created_at | device/cursor/reset-fence metadata and purpose-separated proof/agreement keys; generation-scoped owner via RLS |
| api.device_reset_fences | id; user_id; device_id; fence_version; challenge; cloud_generation; accepted_server_counter_floor; effective_local_counter_floor; reset_required; acknowledged_at; created_at; updated_at | durable per-device reset fence; only reset-fence RPCs expose owner-scoped metadata |
| api.entitlements | id; user_id; store; product_id; transaction_id; original_transaction_id; app_account_token; environment; status; expires_at; revoked_at; verified_at | normalized verification facts; never raw signed transaction |
| api.account_keys | id; user_id; key_version = ASCII [A-Za-z0-9._-]{1,64}; key_fingerprint; rotation_status; client_delivery_status; created_at; activated_at; retired_at | AES-256-GCM account recovery-key metadata; no Vault reference or raw key |
| api.clipboard_items | id; user_id; origin_device_id; mutation_id; content_kind; ciphertext or encrypted_storage_ref; nonce; aad; key_version; ciphertext_hash; revision; created_at; updated_at; tombstone; deleted_at | AES-256-GCM ciphertext and non-secret routing metadata |
| api.assets | id; user_id; item_id; storage_path; ciphertext_hash; byte_count; key_version; upload_state; reservation_expires_at; committed_at; deleted_at | encrypted object reference; private bucket only |
| api.pinboards | id; user_id; mutation_id; encrypted_metadata; revision; created_at; updated_at; tombstone | board metadata is treated as sensitive |
| api.pinboard_items | id; user_id; pinboard_id; item_id; encrypted_order_metadata; mutation_id; revision; tombstone | relationship/order metadata |
| api.sync_changes | revision; user_id; mutation_id; device_id; cloud_generation; entity_type; entity_id; operation; encrypted_change_envelope; created_at | generation-scoped cursor feed; ciphertext only, delete carries tombstone |
| api.semantic_documents | id; user_id; item_id; document_schema_version; redacted_document; semantic_fts = tsvector; embedding = pgvector halfvec(1024); embedding_identity; indexing_generation; index_state; exclusion_state; failure_code; retry_at; indexed_at; updated_at | service-visible derived artifact, not raw clipboard; generation-fenced |
| api.ai_profiles | user_id; platform_provider; platform_policy_version; active_embedding_identity; embedding_model; embedding_dimensions = 1024; byok_key_fingerprint; byok_status; ai_processing_enabled; ai_index_generation; updated_at | AI policy/config, active identity/generation, and BYOK fingerprint metadata; no key material |
| api.usage_counters | user_id; period_start; period_end; cloud_items_used; attachment_bytes_used; ai_requests_used; updated_at | quota/accounting metadata |

### Table-specific rules

1. Mutation IDs are unique per account and are formed as device_id plus a
   monotonic local_counter. A duplicate payload with the same mutation ID is
   idempotent; a different payload with the same ID is an
   IDEMPOTENCY_CONFLICT.
2. Tombstones are durable enough to prevent stale-device resurrection. A
   delete wins over an older update, and pull_changes returns the tombstone
   until the server's retention policy explicitly permits compaction.
3. api.clipboard_items and api.assets never hold plaintext content. A large encrypted
   item uses private Storage and stores only the encrypted reference in
   api.clipboard_items.
4. api.semantic_documents.embedding is a pgvector halfvec(1024). The row's
   `embedding_identity` and `indexing_generation` must match
   `api.ai_profiles.active_embedding_identity` and `ai_index_generation` before
   it can be ranked. A model/tokenizer/identity change marks previous rows
   stale and queues a full resumable rebuild. A row write is accepted only by
   an atomic precondition on user_id, item_id, active identity, enabled AI
   processing, and the same indexing generation; an old generation can never
   become visible after re-enable.
5. index_state and exclusion_state are separate. index_state values are
   pending, processing, ready, stale, failed, or unavailable. exclusion_state
   values are none or user_excluded. A user exclusion is not a recoverable
   failure and is not silently cleared by retry.
6. Cloud clipboard-item and attachment limits are account-level contracts:
   5,000 cloud clipboard items and 250 MB of attachments. Quota exhaustion
   stops new cloud uploads only; local history and existing cloud rows remain.
7. Local history is unlimited by product count. A no-account device uses only
   SQLite and remains fully functional.
8. A single-item delete reuses api.push_mutations with operation=delete. The
   transaction creates or retains a durable tombstone first; a single owner
   deletion worker then cleans that item's ciphertext, referenced Storage
   object, semantic document, FTS data, vector, and eligible sync payload. The
   tombstone is not cleaned by this job and remains until an explicit safe
   compaction gate. An authenticated delete-only mutation is allowed even when
   subscription capabilities are expired; upsert still requires cloud_sync.
9. `cloud_generation` and `cloud_processing_enabled/state` are the server
   authority for cloud work. An all-cloud reset atomically bumps the generation,
   disables cloud processing/sync, invalidates every device cursor and pending
   outbox from the prior generation, rejects old-generation upserts and
   backfill even if entitlement is still active. The old account recovery key
   remains available until cleanup verification, then is deleted. The client
   keeps local history but MUST explicitly re-enable cloud, receive a new
   account key, generation, and enrollment; reset-time local history is never
   automatically backfilled.
   For every device the reset transaction durably records the accepted server
   counter floor, a new fence version and single-use challenge, and marks the
   device reset-required. The reconnecting client computes
   `observed_local_counter_floor` from all locally allocated counters in one
   SQLite transaction; the server stores the maximum of the two on fence ACK.
   The first-ever cloud enable for an account may run the separately specified
   automatic full compliant backfill from SQLite. That initial path is distinct
   from reset/account deletion re-enable: the latter never starts an automatic
   backfill. A future recovery of reset-time local content is only the explicit
   user-initiated reimport action, using new mutation IDs and the current
   enrollment.
   Account deletion performs the same reset before deleting the Auth user last.
10. Deleting all cloud data or deleting the account removes all eligible
   ciphertext/objects/derived artifacts, then removes the account recovery key
   and BYOK Vault secret only after cleanup is verified. Deleting a BYOK
   credential alone immediately disables and destroys that credential without
   deleting other cloud data. Every cleanup is observable and fail-closed.

## Private schema and Vault mapping

The private schema is implementation-only and has no Data API, Realtime, anon,
or authenticated exposure.

| Private relation | Required fields | Purpose |
| --- | --- | --- |
| private.vault_secret_refs | id; user_id; account_key_id nullable; key_version nullable; vault_secret_ref; secret_kind = account_data_key or byok_openrouter_key; rotation_status = active, retiring, revoked; active; created_at; revoked_at | sole opaque Vault-reference mapping; account_data_key requires account_key_id and key_version, BYOK has account_key_id null and at most one active ref; never stores raw key bytes |
| private.ai_tasks | task_id; user_id; item_id; task_kind; indexing_generation; embedding_identity; status; attempt_count; next_retry_at; lease_until; idempotency_key; error_code; created_at; updated_at | durable AI indexing/rebuild task state and generation-fenced wake-up schedule |
| private.deletion_jobs | id; user_id; scope = single_item, semantic_index, all_cloud, account, byok_credential; item_id nullable; idempotency_key; status; phase; attempt; claim_owner; claim_epoch; lease_token; lease_expires_at; heartbeat_at; next_retry_at; error_code; counts; created_at; updated_at; started_at; completed_at | private deletion ledger and single-worker lease fence state; never Data API exposed |
| private.reenable_operations | operation_id; user_id; scope = cloud_sync or semantic_index; idempotency_key; expected_cloud_generation; expected_indexing_generation; expected_reset_fence_id; terminal_deletion_job_id; status; cloud_generation; account_key_version; enrollment_generation; indexing_generation; active_embedding_identity; error_code; created_at; updated_at; completed_at | durable re-enable idempotency/status/CAS ledger; never Data API exposed |
| private.bootstrap_operations | operation_id; user_id; scope = cloud_sync or semantic_index; device_id; platform; signing_key_fingerprint; key_agreement_key_fingerprint; challenge_id; idempotency_key; status; cloud_generation; account_key_version; enrollment_generation; indexing_generation; active_embedding_identity; error_code; created_at; updated_at; completed_at | one-time initial-enable idempotency/status ledger and proof audit metadata; never Data API exposed |
| private.device_proof_challenges | challenge_id; user_id; device_id; purpose = register or key_delivery; nonce_digest; expires_at; consumed_at; revoked_at; created_at | single-use challenge for the byte-exact v1 P-256 proof; never Data API exposed |
| private.account_key_deliveries | delivery_id; user_id; device_id; enrollment_generation; key_version; challenge_id; request_context_hash; idempotency_key; status; expires_at; created_at; completed_at | idempotency/status ledger only; original account key exists remotely only in Vault, and envelope/key material are never stored; never Data API exposed |
| private.asset_reservations | reservation_id; user_id; device_id; item_id; asset_id; object_path; ciphertext_hash; byte_count; key_version; status = reserved, committed, cancelled, expired; expires_at; created_at; updated_at | private upload metadata authorization/commit state; never Data API exposed |
| private.operation_capability_assertions | assertion_id; user_id; capability = platform_ai or byok_ai; entitlement_version; request_id; request_hash; expires_at; consumed_at; revoked_at; created_at | short-lived single-use Edge-to-private.match_clipboard capability; never Data API exposed |

ai_tasks status values are queued, running, succeeded, failed, cancelled, or
stale. `indexing_generation` and `embedding_identity` prevent a paused/closed
client or an older rebuild from committing late results. Task leases and
provider-await return paths are checked again in the database before any
semantic document/vector write. Task payloads contain item IDs and
redacted/encrypted references only; they never contain raw clipboard content or
BYOK keys.

`private.bootstrap_operations` is the sole durable initial-enable ledger. Its
trusted Edge owner locks the relevant profile/device or AI state, creates the
initial key/generation/enrollment or AI identity exactly once, and returns the
same operation for an idempotent retry. A scope already initialized under a
different idempotency key returns `BOOTSTRAP_ALREADY_INITIALIZED`; it never
rotates or silently reopens an existing scope. The initiating device enrollment
is server-minted. Initial cloud backfill cannot start until the bootstrap
operation succeeded and `POST /functions/v1/account-key-delivery` completed.

`private.deletion_jobs` is the sole deletion ledger. Its status values are
requested, in_progress, succeeded, and failed; phases include tombstone,
payload_cleanup, asset_cleanup, semantic_cleanup, vault_cleanup,
auth_delete_pending, and complete. One `DeletionWorker` actor/service owns
every job, atomically claims one lease with `claim_owner`,
`lease_expires_at`, and `heartbeat_at`, advances `attempt` and `next_retry_at`,
records safe counts and error_code, and retries only through its durable wake
path. Only the single worker owner may advance a claimed phase; a lease expiry
permits recovery by a new claim. The deterministic idempotency key is unique
per user, scope, and item (when present), and there is at most one nonterminal
job for the same logical deletion. A nonterminal job makes affected upsert,
semantic indexing, rebuild, and backfill operations fail with
DELETION_IN_PROGRESS; a worker never permits a late task to recreate deleted
data. For `semantic_index`, the deletion transaction first atomically disables
AI processing and bumps `ai_index_generation`, then cancels/marks stale old
tasks and removes semantic documents, FTS, vectors, and query cache. It requires
explicit re-enable before rebuilding;
ciphertext, Storage, account keys, and BYOK credentials remain. Settings reads
job state only through the status endpoint below; the private relation is never
Data API exposed. Internal `private.claim_deletion_job`,
`private.heartbeat_deletion_job`, and `private.advance_deletion_job` calls are
service-role/trusted-worker only, use fixed search paths, and have no Data API
or authenticated execution grant.

The internal worker calls are fixed as follows and are not client APIs:

    private.claim_deletion_job({ worker_id, now, lease_duration })
      -> { job_id, scope, phase, attempt, claim_epoch, lease_token,
           lease_expires_at } | null
    private.heartbeat_deletion_job({ job_id, worker_id, claim_epoch,
                                     lease_token, lease_extension })
      -> { job_id, claim_epoch, lease_token, lease_expires_at, heartbeat_at }
    private.advance_deletion_job({ job_id, worker_id, claim_epoch, lease_token,
                                   expected_phase, next_phase, result_counts,
                                   error_code })
      -> { job_id, status, phase, next_retry_at }

`claim_deletion_job` atomically selects one nonterminal unclaimed or expired
lease, increments `attempt` and monotonic `claim_epoch`, and mints a new unique
`lease_token`; `worker_id` is diagnostic only. Heartbeat and advance MUST match
job, claim_epoch, lease_token, and an unexpired lease. Reclaim always changes
the token, so an old await, ABA reuse, restart, or late worker returns
`DELETION_LEASE_LOST` and cannot advance the phase. These calls are the only
way to mutate deletion phase/status, and the deterministic job key makes
retries return the same durable job.

The trusted Storage metadata calls are fixed as follows and are not client
APIs:

    private.reserve_asset_upload_metadata({ user_id, device_id, item_id,
      asset_id, cloud_generation, idempotency_key, ciphertext_hash,
      byte_count, key_version })
      -> { reservation_id, object_path, expires_at } | error
    private.cancel_asset_upload_metadata({ reservation_id, error_code })
      -> { reservation_id, status: cancelled }
    private.commit_asset_upload_metadata({ user_id, reservation_id, asset_id,
      object_path, ciphertext_hash, byte_count, cloud_generation })
      -> { asset_id, revision, status: committed } | error

Only the trusted Edge Storage signer may call these private transactions. The
private functions never sign URLs, and the signer never receives a Vault key.

Device proof and key-delivery authorization metadata is also private-only:

    private.bind_device_registration({ user_id, device_id, scope, platform,
      device_signing_public_key, device_key_agreement_public_key,
      challenge_id, proof_signature, request_context_hash, idempotency_key,
      cloud_generation })
      -> { device_id, enrollment_generation, reset_required } | error
    private.authorize_account_key_delivery({ user_id, device_id,
      enrollment_generation, requested_key_version, challenge_id,
      proof_signature, request_context_hash, idempotency_key })
      -> { delivery_id, key_version, device_key_agreement_public_key,
           expires_at } | error

These transactions verify the challenge purpose, nonce digest, canonical
proof message/context hash, same-user binding, purpose-separated public keys,
current enrollment/reset fence, capability, and key rotation state under the
profile/device lock. They never return or store account-key bytes. Only the
authenticated Edge caller may then read the account recovery key from Vault in
memory and build the response envelope; neither function has a Data API or
authenticated execution grant.

The trusted Edge capability handoff is also private-only:

    private.create_operation_capability_assertion({ user_id, capability,
      entitlement_version, request_id, request_hash, expires_at })
      -> { assertion_id, expires_at }

Only `trusted_edge` may create it after checking the current Supabase identity
and named entitlement; only `private.match_clipboard` may consume it. The
`request_hash` is the canonical hash of user, active identity, indexing
generation, `semantic_query`, filters, and limit; it excludes raw clipboard
content and is persisted only as a binding value. The assertion is short-lived,
single-use, request-bound, and never exposed through the Data API or Swift
client.

For every asynchronous AI task, the provider-await return path and the final
semantic-document/vector write MUST perform one database-atomic precondition
covering user ownership, `ai_profiles.ai_processing_enabled`, the active
embedding identity, and the task's `indexing_generation`. A failed precondition
returns `AI_GENERATION_STALE` and commits no derived artifact. The
semantic-index deletion transaction performs the disable-and-bump before task
cancellation or artifact deletion, so an old task cannot commit during cleanup
or become visible after a later re-enable.

The deletion boundary is fixed rather than left to WP1/WP5 invention:

1. `POST /functions/v1/deletion-request` is an authenticated Edge endpoint
   owned by the DeletionWorker boundary. It requires a valid Supabase user JWT
   but does not require `cloud_sync`, because delete-only cleanup remains
   allowed with a valid auth session after subscription/entitlement expiry.
   Its request is:

       {
         idempotency_key: String,
         scope: semantic_index | all_cloud | account | byok_credential
       }

   It returns `{ job_id, scope, status, phase, counts, next_retry_at }` and
   creates or returns the same job for a repeated `(user_id, scope,
   idempotency_key)`.
2. `GET /functions/v1/deletion-status?job_id=...` is an authenticated owner
   status endpoint. It returns `{ job_id, scope, status, phase, attempt,
   next_retry_at, error_code, counts, created_at, updated_at,
   completed_at }` and never returns content, key material, or Vault
   references. Account-scope status is available through `auth_delete_pending`
   until the final Auth deletion; after that user deletion, no user-owned
   status query is expected.

3. `POST /functions/v1/re-enable` is the only re-enable boundary. It requires
   a valid Supabase identity JWT and an active named capability: `cloud_sync`
   for `scope=cloud_sync`, or `platform_ai`/`byok_ai` for
   `scope=semantic_index`. It is not available while any affected deletion job
   is nonterminal. Its request is:

       {
         idempotency_key: String,
         scope: cloud_sync | semantic_index,
         expected_cloud_generation: UUID | null,
         expected_indexing_generation: UUID | null,
         expected_reset_fence_id: UUID | null,
         terminal_deletion_job_id: UUID
       }

   The server locks the profile/AI state, verifies the expected generation and
   reset fence, verifies that `terminal_deletion_job_id` is the terminal job
   for the requested scope and that no newer deletion intent exists, then
   atomically performs the scope transition and returns
   `{ operation_id, scope, status, cloud_generation, account_key_version,
   enrollment_generation, indexing_generation, active_embedding_identity }`.
   Cloud re-enable creates and activates a new account-key version, cloud
   generation, and server-minted enrollment before any newly authorized sync;
   it never auto-backfills reset-time local history. AI re-enable creates a new
   indexing generation and a new active embedding identity before any rebuild,
   and old vectors remain invisible.
   Repeating `(user_id, scope, idempotency_key)` returns the same operation and
   status. A delayed request whose expected state no longer matches returns
   `REENABLE_PRECONDITION_FAILED` and cannot reopen processing. The operation is
   observable through
   `GET /functions/v1/re-enable-status?operation_id=...`, which uses the same
   valid-identity-session and owner checks and never returns key material.

The five scopes are distinct. A `single_item` job is created by the delete
mutation described below. `semantic_index` first disables AI/index processing
and atomically bumps the indexing generation, then removes only semantic
documents, FTS, vectors, AI tasks, and query cache; it requires explicit
re-enable before rebuild and preserves ciphertext, Storage,
account keys, and BYOK credentials. `all_cloud` cleans every cloud payload, Storage
object, semantic artifact, vector, and eligible sync payload, then removes the
account recovery key and BYOK Vault secret after cleanup verification while
leaving the Auth user. `account` performs the same data-first cleanup, then
removes both Vault secrets, marks cleanup verified, and deletes the Supabase
Auth user last. `byok_credential` disables and destroys only the BYOK secret
and fingerprint. These endpoints require a valid Supabase auth session and
remain callable with an expired subscription/entitlement for cleanup only; an
expired or invalid JWT is always denied. They never retrieve or use a remote
secret during cleanup.

Only `private.vault_secret_refs.vault_secret_ref` stores an opaque Vault
reference. For `secret_kind=account_data_key`, `account_key_id` is required and
there is exactly one reference per `(user_id, account_key_id, key_version)`.
Rotation creates and activates the new reference first while the old reference
becomes `retiring` and remains decryptable/recoverable. Only after reencryption,
required device acknowledgements, and the safe rotation gate may the old
reference be revoked/deleted; it is never revoked before or simultaneously with
new activation.
For `secret_kind=byok_openrouter_key`, `account_key_id` is null and there is at
most one active reference per user; replacement atomically switches the active
reference and then destroys the old secret. `api.account_keys` and
`api.ai_profiles` never store or repeat an opaque Vault reference.

The account data encryption key is created, authorized, and rotated under the
Vault-backed account-key flow. An authenticated, authorized device receives the
actual key material only through the `POST /functions/v1/account-key-delivery`
device-bound envelope while `cloud_sync` is active, and stores it in Keychain
or secure storage for local AES-256-GCM encryption/decryption. The service
retains the recovery copy in Vault and can recover the key. api.account_keys
records key_version and rotation_status; rotation creates
and activates the new version while the old version is `retiring` and remains
decryptable/recoverable. Only after reencryption, required device acknowledgements,
and a safe rotation gate is the old reference revoked/deleted. A new device is
denied remote account-key recovery after expiry; an already cached key remains
available only for local decryption. Account-key deletion occurs only with
all-cloud/account deletion, after ciphertext cleanup is verified. All remote
Vault secret retrieval/use stops at expiry.

The BYOK OpenRouter key follows a separate flow. Supabase Vault is the only
place containing its raw key; the client can receive only the fingerprint and
status and can request test, replacement, or destruction, never read-back.
Expiry/revocation immediately disables BYOK use. Explicit BYOK deletion removes
that Vault secret and fingerprint only; it does not delete cloud data or the
account recovery key. private.vault_secret_refs secret_kind values distinguish
account_data_key from byok_openrouter_key.

## Storage contract

The bucket name is an implementation value, but the bucket SHALL be private.
Object paths are scoped to user_id and asset_id. SQL/Data API RPCs never sign
Storage URLs. Public URLs, unrestricted list operations, and plaintext object
uploads are forbidden.

`POST /functions/v1/asset-upload-reserve` is an authenticated Edge endpoint.
It requires a valid identity JWT, owner binding, current generation, enabled
cloud processing, and `cloud_sync`. The Edge first calls a trusted private
metadata authorization/reservation transaction, then uses its Supabase Storage
service client (credential exists only in the Edge runtime secret boundary) to
sign the exact private bucket/object path for ciphertext upload with a short
TTL. If signing fails, the Edge cancels/rolls back the reservation and returns
`ASSET_SIGNING_FAILED`; it never returns a partial capability. The response is
`{ reservation_id, object_path, signed_upload_url, required_headers,
expires_at }`. The URL is a short-lived bearer capability bound to the exact
object path, byte/hash headers, user, and reservation; it is not claimed to be
single-use unless the Storage primitive guarantees that property.

`POST /functions/v1/asset-upload-commit` is also Edge-only. It requires a valid
identity JWT, `cloud_sync`, and the current generation. The Edge verifies
reservation owner/status/expiry, exact object path, object existence, byte
count, and ciphertext hash, then calls the trusted private commit transaction.
The response is `{ asset_id, state, revision, object_path }`; commit is
idempotent. Missing, expired, or mismatched objects remain uncommitted and are
eligible for cleanup.

`POST /functions/v1/asset-download-capability` requires only a valid identity
session and owner/RLS authorization, so a valid identity session may export
after commercial expiry. The Edge first authorizes the exact encrypted object, then
signs an exact private bucket/object path with a short TTL. Its response is
`{ asset_id, object_path, signed_download_url, expires_at }`. This is a
short-lived replayable bearer URL until expiry if Storage cannot provide
single-use semantics; it is never described as single-use. It cannot access
Vault, account keys, or plaintext. URLs/tokens are not logged, persisted in
diagnostics, or returned by `api.export_encrypted`.

The reservation is committed only after the server verifies object existence,
byte count, and ciphertext hash. A reservation not committed within 24 hours
is an orphan-cleanup candidate. Cleanup MUST not remove a committed object
that is still referenced by a non-tombstoned clipboard item.

## Cursor and mutation semantics

The server maintains a monotonically increasing per-account revision. A
revision is an ordering cursor, not an item version chosen by the client.
pull_changes returns changes after the requested cursor, a next cursor, a
has_more flag, and the server's current revision. Realtime carries only the
latest known revision and cannot replace a pull.

The client applies a pull atomically to SQLite, advances its durable cursor,
then acknowledges the cursor. A lost or duplicated notification is harmless.
An invalid or compacted cursor returns a typed error; the client performs the
documented full-recovery path rather than guessing or treating a notification
as data.

SyncCoordinator is the only owner of enqueue, drain, timer/background retry,
cancellation, and generation. It MUST reject duplicate enqueue and concurrent
drain. Pausing, closing, logout, or entitlement expiry cancels the current
generation. The server remains idempotent if a cancelled request completes
after cancellation.

## Common RPC envelope

All exposed RPCs use one structured result shape:

    {
      request_id: UUID,
      data: object | null,
      error: {
        code: string,
        message: string,
        retryable: boolean,
        details: object | null
      } | null
    }

The message is safe for UI diagnostics and MUST not contain clipboard content,
raw tokens, URLs supplied by a user, key material, or provider response bodies.
The request_id is for tracing and idempotency correlation, not a secret.

Every client-exposed api RPC requires a valid Supabase user JWT. The function
derives user_id from auth.uid(), applies RLS/owner checks, and performs the
operation-specific named-capability check when that operation needs one.
Anonymous calls fail closed. `pull_changes`, `ack_revision`,
`export_encrypted`, reset-fence pull/ACK, and delete/cleanup are identity-only
owner operations subject to enabled-state, generation, fence, and deletion
preconditions; they do not require commercial entitlement. All mutation RPCs
accept an explicit idempotency key or mutation ID and return the same result
for a retry of the same request. Internal cleanup/verification jobs use a
separate locked-down service path.

The identity JWT remains a login/owner proof after subscription expiry and may
authorize owner-scoped read/export/delete/cleanup. It does not prove
`cloud_sync`, `platform_ai`, `byok_ai`, or remote Vault access. Those operations
perform a fresh named-capability check; operation assertions are short-lived
and revalidated before and after every remote await.

`private.match_clipboard` is not client-exposed and has no anon or authenticated
EXECUTE grant. Only `service_role` or a dedicated `trusted_edge` role may call
it, after the Edge endpoint has revalidated the user's session and
`platform_ai`/`byok_ai` capability. The restricted function receives an
internal capability assertion and an explicit `p_user_id`; it does not derive
authorization from a service-role `auth.uid()` value.

## RPC contracts

### api.push_mutations

Request:

    {
      device_id: UUID,
      cloud_generation: UUID,
      reset_fence_id: UUID,
      enrollment_generation: UUID,
      client_seen_revision: Int64,
      mutations: [
        {
          mutation_id: String,
          local_counter: Int64,
          creation_enrollment_generation: UUID,
          entity_type: clipboard_item | asset_ref | pinboard | pinboard_item,
          entity_id: UUID,
          operation: upsert | delete,
          encrypted_change_envelope: object | null,
          tombstone: boolean
        }
      ]
    }

The batch is bounded and contains encrypted envelopes only. Before accepting
any batch, the server requires the device's current reset fence and completed
re-enrollment. `reset_required`, an unacknowledged fence, a stale
`enrollment_generation`, or a local_counter at/below the recorded floor fails
closed. Each mutation's immutable `creation_enrollment_generation` is checked
against the server-minted current enrollment; changing only the batch field
cannot make a reset-preceding mutation valid. The server accepts
upserts and backfill only when `cloud_generation` equals the active profile and
`cloud_processing_enabled` is true. A stale generation or disabled state is
rejected even when entitlement is active. A delete carries a
tombstone and does not require ciphertext. Upsert or asset mutations require
`cloud_sync`; an authenticated batch containing only `operation=delete` remains
valid after subscription expiry for delete-only cleanup. A mixed batch without
`cloud_sync` fails closed. The server verifies that device_id belongs to
auth.uid(), assigns revisions transactionally, and applies tombstone-wins
ordering. Reset-time outbox rows are isolated locally and are never
automatically backfilled; a future user import creates new mutation identities.

For every delete mutation, the transaction creates or retains the durable
tombstone before creating a `private.deletion_jobs` row with
`scope=single_item`. The single owner worker asynchronously or transactionally
cleans the item's ciphertext, Storage object, semantic document, FTS/vector,
and eligible sync payload. It never removes the tombstone; stale devices
cannot resurrect the item. Upsert, indexing, rebuild, and backfill attempts
while this job is nonterminal return `DELETION_IN_PROGRESS`.

Response:

    {
      accepted: [{ mutation_id, revision, deletion_job_id: UUID | null }],
      duplicate: [{ mutation_id, revision, deletion_job_id: UUID | null }],
      rejected: [{ mutation_id, error_code }],
      server_revision: Int64,
      next_pull_cursor: Int64,
      quota_state: { cloud_uploads_allowed, attachment_bytes_remaining }
    }

A duplicate delete returns the same `deletion_job_id` and shape as the original
accepted result, so a lost first response can be retried and observed through
the status endpoint. A rejected mutation does not make unrelated mutations fail.
The client keeps a
retryable rejection in SQLite with next_retry_at; permanent policy/key errors
are visible and fail closed.

### api.pull_reset_fence

Request:

    { device_id: UUID, known_reset_fence_id: UUID | null }

The authenticated device calls this before normal pull or push whenever it
reconnects after an all-cloud/account reset. It requires a valid identity JWT
but no commercial capability because it returns only owner-scoped reset
metadata. The response is:

    {
      reset_required: Bool,
      reset_fence_id: UUID,
      fence_version: Int64,
      challenge: String,
      reset_generation: UUID,
      cloud_generation: UUID,
      accepted_server_counter_floor: Int64,
      enrollment_generation: UUID | null,
      action: isolate_pre_reset_outbox | none
    }

The client atomically persists the fence, isolates/discards only reset-preceding
outbox work from cloud processing, and keeps the corresponding history local.

### api.ack_reset_fence

Request:

    {
      device_id: UUID,
      active_fence_id: UUID,
      expected_fence_version: Int64,
      expected_challenge: String,
      observed_local_counter_floor: Int64
    }

The device sends this only after the local fence transaction succeeds. It
requires a valid identity JWT but no commercial capability; subsequent push
still requires `cloud_sync`. The server CAS-verifies the active fence,
`expected_fence_version`, and challenge, computes
`effective_local_counter_floor = max(accepted_server_counter_floor,
observed_local_counter_floor)`, records the ACK, and mints the new
`enrollment_generation` itself. The request cannot supply that generation. It
returns `{ reset_fence_id, fence_version, cloud_generation,
effective_local_counter_floor, enrollment_generation, push_allowed: true }`;
retries are idempotent. Until this ACK/re-enrollment is recorded,
`push_mutations` fails with `RESET_FENCE_REQUIRED` or
`DEVICE_REENROLLMENT_REQUIRED`. A fence CAS mismatch returns
`RESET_FENCE_CONFLICT` and requires re-pull. Re-enable never auto-imports
reset-time local history; a user-triggered reimport is required and must emit
new mutation IDs with the current enrollment.

### POST /functions/v1/register-device

Request:

    {
      device_id: UUID,
      platform: macOS | iOS,
      scope: cloud_sync,
      device_signing_public_key: P-256 ECDSA public key,
      device_key_agreement_public_key: P-256 ECDH public key,
      challenge_id: UUID,
      proof_signature: P-256 ECDSA/SHA-256 signature,
      request_context_hash: SHA-256 digest,
      idempotency_key: String
    }

This authenticated Edge endpoint requires a valid identity JWT and active
`cloud_sync`. It verifies the single-use `purpose=register` challenge and
ECDSA signature against the supplied signing public key, binds `device_id` to
`auth.uid()` through the authoritative private metadata transaction, rejects
an expired capability or an unacknowledged reset fence, and server-mints the
device's `enrollment_generation`. It returns
`{ device_id, cloud_generation, enrollment_generation, reset_required }` and is
idempotent for the same owner/device/proof. It cannot return account-key
material; `POST /functions/v1/account-key-delivery` is the separate
device-bound envelope flow. A reset-required device must complete
`pull_reset_fence`/`ack_reset_fence` rather than registering around the fence.

### api.pull_changes

Request:

    {
      device_id: UUID,
      cloud_generation: UUID,
      cursor: Int64,
      limit: Int
    }

The caller must have a valid identity JWT, owner/RLS authorization,
`cloud_processing_enabled=true`, the current `cloud_generation`, and an
acknowledged reset fence; no commercial capability is required. The cursor is
account-scoped and the limit is bounded by the server. A stale generation or
disabled processing state returns
`CLOUD_GENERATION_STALE` or `CLOUD_PROCESSING_DISABLED` and requires explicit
re-enable rather than accepting old outbox/cursor data. Response:

    {
      changes: [
        {
          revision,
          mutation_id,
          device_id,
          entity_type,
          entity_id,
          operation,
          encrypted_change_envelope,
          tombstone
        }
      ],
      next_cursor: Int64,
      has_more: Bool,
      server_revision: Int64,
      cloud_generation: UUID,
      cloud_processing_state: enabled | disabled | reset
    }

The response is the only remote data feed consumed by the client. It is
committed to SQLite atomically; a WebSocket event is never merged directly.

### api.export_encrypted

Request:

    {
      cursor: Int64,
      limit: Int,
      device_id: UUID
    }

This owner-scoped paginated export requires only a valid Supabase identity
session and RLS/owner checks; it does not require commercial entitlement or
Vault access. It returns encrypted envelopes and non-secret metadata only:

    {
      encrypted_items: [{ item_id, mutation_id, key_version,
                          encrypted_change_envelope, tombstone }],
      encrypted_attachments: [{ asset_id, item_id, byte_count,
                                ciphertext_hash, key_version }],
      next_cursor: Int64,
      has_more: Bool
    }

Export returns attachment IDs and non-secret encrypted-object metadata only.
The client requests a separate `POST /functions/v1/asset-download-capability`
when it needs a short-lived URL. That Edge signer is owner-scoped and cannot
retrieve an account key or BYOK secret. Export never returns signed URLs,
plaintext, semantic query text, or Vault references.

### api.ack_revision

Request:

    { device_id: UUID, cloud_generation: UUID, cursor: Int64 }

Response:

    { acknowledged_cursor: Int64, server_revision: Int64 }

The caller must have a valid identity JWT, owner/RLS authorization, an enabled
cloud-processing state, the current generation, and an acknowledged reset
fence; no commercial capability is required. A stale generation returns
`CLOUD_GENERATION_STALE`. The call is idempotent and may acknowledge an already
acknowledged cursor.
Acknowledgement never authorizes a write and never deletes local queue rows
that have not received an accepted mutation result.

### Edge asset-upload endpoints (not Data API RPCs)

The following endpoints are authenticated Edge contracts. Their private
metadata transactions are not client-exposed and no SQL/Data API function signs
or returns a Storage URL.

`POST /functions/v1/asset-upload-reserve` request:

    {
      idempotency_key: String,
      device_id: UUID,
      cloud_generation: UUID,
      asset_id: UUID,
      item_id: UUID,
      ciphertext_hash: String,
      byte_count: Int64,
      key_version: String,
      content_kind: String
    }

Edge response:

    {
      reservation_id: UUID,
      object_path: String,
      signed_upload_url: String,
      required_headers: object,
      expires_at: Timestamp,
      remaining_attachment_bytes: Int64
    }

The Edge requires `cloud_sync`, enabled cloud processing, and the current
generation; stale generations fail with `CLOUD_GENERATION_STALE`. It calls
`private.reserve_asset_upload_metadata` before signing and cancels the
reservation if signing fails. The URL is for ciphertext only and is never
logged or persisted as a reusable credential. Repeating the idempotency key
returns the same reservation or a typed conflict.

`POST /functions/v1/asset-upload-commit` request:

Request:

    {
      idempotency_key: String,
      device_id: UUID,
      cloud_generation: UUID,
      reservation_id: UUID,
      asset_id: UUID,
      ciphertext_hash: String,
      byte_count: Int64
    }

Edge response:

    {
      asset_id: UUID,
      state: committed,
      revision: Int64,
      object_path: String
    }

The Edge requires `cloud_sync`, enabled cloud processing, and the current
generation; stale generations fail with `CLOUD_GENERATION_STALE`. It verifies
reservation ownership, expiry, exact object path, object existence, size, and
hash, then calls `private.commit_asset_upload_metadata`. Commit is idempotent.
Missing, expired, or mismatched objects remain uncommitted and are eligible for
cleanup; no plaintext retry is allowed. The private reserve/commit functions
are trusted-only, fixed-search-path transactions with no Data API or
anon/authenticated EXECUTE grant.

`POST /functions/v1/asset-download-capability` request:

    {
      asset_id: UUID,
      item_id: UUID,
      audience: clipboard_export | attachment_download
    }

The valid identity-session Edge call performs owner/RLS authorization before
the Storage signer issues an exact-object short-TTL URL. It returns
`{ asset_id, object_path, signed_download_url, expires_at }`; the URL is a
replayable bearer capability until expiry when Storage lacks single-use support.
It never returns Vault/key material and never logs the URL or token.

### private.match_clipboard

This is a restricted database RPC, not a client-facing API. The client calls
only the authenticated Supabase Edge semantic-search endpoint. Its client
request body contains only:

    {
      query: String,
      filters: object,
      limit: Int
    }

The Edge generates an internal `request_id` after receiving this client
request and derives a canonical `request_hash`; neither is a client contract
field. The hash covers the verified user, active embedding identity, indexing
generation, semantic query, filters, and limit, and excludes raw clipboard
content.

The client performs the sensitive-query gate before sending this request. The
Edge endpoint revalidates the Supabase session and the concrete
`platform_ai`/`byok_ai` capability, keeps the approved query transient, applies
the ZDR/multimodal policy to both platform and BYOK routes, and calls OpenRouter
for the active 1024-dimensional
query embedding and semantic query representation. After every provider await,
it revalidates session and capability again. The client never creates or sends
a halfvec query embedding.

The trusted Edge/service call into this RPC has the following request. It is
not reachable through the client Data API:

    {
      p_user_id: UUID,
      assertion_id: UUID,
      p_request_id: UUID,
      p_request_hash: String,
      query_embedding: halfvec(1024),
      semantic_query: String,
      filters: object,
      limit: Int
    }

Only `service_role` or `trusted_edge` may execute it. The RPC does not call an
AI provider and the service role itself is never treated as a capability. The
trusted Edge first creates a short-lived single-use row through
`private.operation_capability_assertions` after the current session and
entitlement check. In the same database transaction, this RPC verifies
`assertion_id` is bound to `p_user_id`, has capability `platform_ai` or
`byok_ai`, matches the current entitlement version, `p_request_id`, and
`p_request_hash`, and is not expired/revoked/consumed; the RPC then consumes it
in the same transaction. Any missing, wrong-user, wrong-capability,
wrong-request, wrong-hash, expired, revoked, or consumed assertion rejects the
search before vector/FTS work. Its fixed search_path and trusted-context check
also hard-scope every predicate to the verified `p_user_id`; the service role
is never shipped to a client.
It checks the active embedding identity and queries
`api.semantic_documents.embedding` and
`api.semantic_documents.semantic_fts`. Raw query text is not persisted.

Response:

    {
      state: ready | partial | failed | unavailable,
      vector_matches: [{ item_id, rank, score }],
      semantic_fts_matches: [{ item_id, rank, score }],
      index_summary: {
        ready_count,
        pending_count,
        stale_count,
        failed_count,
        user_excluded_count
      }
    }

The two arrays are intentionally independent rank lists. Local lexical
matching happens in SQLite and is not part of this RPC. The client performs
three-way RRF over vector, semantic FTS, and local lexical lists only after the
UI sparkle action; an explicit MCP tool invocation may use the same retrieval
contract without being a sparkle action. No UI remote call is triggered by
typing or Enter.

## Error taxonomy

The error object uses one machine-readable code and a retryable boolean:

| Code | Retryable | Meaning |
| --- | --- | --- |
| AUTH_REQUIRED / AUTH_INVALID | no | missing, expired, or invalid Supabase session |
| CAPABILITY_REQUIRED / SUBSCRIPTION_EXPIRED | no | the named cloud_sync, platform_ai, or byok_ai capability is not currently valid |
| BOOTSTRAP_ALREADY_INITIALIZED / BOOTSTRAP_PRECONDITION_FAILED | no | initial-enable scope is already provisioned or its owner/capability/device precondition changed |
| DEVICE_REGISTRATION_REQUIRED / DEVICE_ENROLLMENT_STALE | no | a new device needs server enrollment, or reset fence ACK must complete before push |
| DEVICE_PROOF_REQUIRED / DEVICE_PROOF_INVALID / DEVICE_PROOF_EXPIRED / DEVICE_PROOF_REPLAYED | no | challenge is missing, not a valid P-256 proof for the bound user/device/purpose, expired, or already consumed |
| DEVICE_ID_CONFLICT / DEVICE_SIGNING_KEY_MISMATCH / DEVICE_KEY_AGREEMENT_MISMATCH | no | device UUID is bound to another user or a retry presents a different registered purpose-separated public key |
| PROOF_ENCODING_INVALID / PROOF_LENGTH_INVALID / PROOF_CONTEXT_MISMATCH | no | base64url, UUID16, enum, X9.63 point, IEEE-P1363 signature, nonce digest, or exact v1 context/message encoding is invalid |
| KEY_DELIVERY_UNAUTHORIZED / KEY_DELIVERY_REPLAYED / KEY_DELIVERY_VERSION_UNAVAILABLE / KEY_DELIVERY_RETRY_REQUIRED | no | account-key delivery lacks capability/owner/enrollment/reset proof, reuses a challenge, requests revoked/unavailable key version, or needs a fresh challenge for a non-persisted envelope retry |
| KEY_ENVELOPE_ENCODING_INVALID / KEY_ENVELOPE_POINT_INVALID / KEY_ENVELOPE_TAG_INVALID | no | envelope binary length/encoding, X9.63 point/shared secret, AAD/HKDF reconstruction, or constant-time AES-GCM tag verification failed |
| ACCOUNT_SUSPENDED / DEVICE_REVOKED | no | owner is blocked from this operation |
| SCHEMA_UNSUPPORTED | no | client contract version cannot be served |
| MUTATION_INVALID / IDEMPOTENCY_CONFLICT | no | malformed envelope or reused ID with different data |
| CURSOR_INVALID / CURSOR_TOO_OLD / REVISION_GAP | no | cursor recovery is required |
| QUOTA_CLOUD_ITEMS / QUOTA_ATTACHMENT_BYTES | no | stop new cloud upload; preserve local/existing data |
| CIPHERTEXT_INVALID / AAD_INVALID / KEY_VERSION_UNSUPPORTED | no | cryptographic verification failed; never downgrade |
| SENSITIVE_CONTENT_BLOCKED | no | client or server policy refused upload |
| ASSET_RESERVATION_EXPIRED / ASSET_CHECKSUM_MISMATCH / ASSET_NOT_FOUND | no | upload lifecycle must restart safely |
| ASSET_SIGNING_FAILED / ASSET_DOWNLOAD_UNAUTHORIZED | yes | Edge Storage signing failed and reservation was cancelled, or owner/object binding failed |
| ZDR_POLICY_UNAVAILABLE | no | no verified zero-retention AI endpoint |
| EMBEDDING_IDENTITY_STALE / INDEX_NOT_READY | yes | rebuild or readiness transition is pending |
| INDEX_EXCLUDED | no | user exclusion, distinct from failure |
| VAULT_UNAVAILABLE | yes | retry after Vault health/entitlement check |
| RATE_LIMITED / RETRYABLE_UNAVAILABLE | yes | bounded backoff with durable wake-up |
| MCP_VISIBILITY_CHANGED | no | re-check authorization/visibility and do not return payload |
| DELETION_IN_PROGRESS | yes | do not recreate or expose data during cleanup |
| CLOUD_GENERATION_STALE | no | device outbox/cursor belongs to a reset generation; retain local history and require explicit re-enable |
| CLOUD_PROCESSING_DISABLED | no | cloud processing is disabled after reset; no upsert or backfill is accepted |
| AI_GENERATION_STALE | no | semantic task or index result belongs to a disabled/older AI generation |
| AI_CAPABILITY_ASSERTION_INVALID / AI_CAPABILITY_ASSERTION_CONSUMED / AI_REQUEST_BINDING_INVALID | no | trusted Edge assertion is missing, mismatched, expired, revoked, consumed, wrong-user/capability, or bound to a different request/hash; do not search |
| RESET_FENCE_REQUIRED / DEVICE_REENROLLMENT_REQUIRED | no | device must pull, locally isolate pre-reset outbox, ACK the reset fence, and re-enroll before push |
| LOCAL_COUNTER_BELOW_FLOOR | no | mutation is from before the reset fence floor; create a new mutation identity after explicit import |
| RESET_FENCE_CONFLICT | no | fence version/challenge CAS failed; re-pull the current fence before ACK |
| REENABLE_PRECONDITION_FAILED | no | expected generation/fence/deletion terminal state changed; do not reopen processing |
| DELETION_LEASE_LOST | yes | claim lease/token no longer matches or expired; do not advance the old job phase |

No error path may silently fall back to local snapshot data as cloud truth,
plaintext upload, a custom provider URL, an old embedding dimension, or an
expired entitlement.

## Swift protocol signatures (documentation only)

The following are contract signatures, not implementation code. Concrete
models, storage adapters, and error types are defined by later work packages.
The implementation MUST preserve actor isolation, Sendable boundaries, and
async cancellation semantics.

    public protocol LocalSQLiteReadSource: Sendable {
        func readPage(query: LocalQuery, cursor: LocalCursor?) async throws -> LocalPage
        func readItem(id: UUID) async throws -> LocalClipboardItem?
        func readPendingMutations(limit: Int) async throws -> [LocalMutation]
        func applyRemoteChanges(_ changes: [RemoteChange], cursor: Int64) async throws
        func markMutationResult(_ result: MutationResult) async throws
    }

    public protocol SupabaseSyncTransport: Sendable {
        func pushMutations(_ request: PushMutationsRequest) async throws -> PushMutationsResponse
        func pullResetFence(_ request: PullResetFenceRequest) async throws -> ResetFenceResponse
        func ackResetFence(_ request: AckResetFenceRequest) async throws -> ResetFenceAckResponse
        func pullChanges(_ request: PullChangesRequest) async throws -> PullChangesResponse
        func exportEncrypted(_ request: EncryptedExportRequest) async throws -> EncryptedExportResponse
        func ackRevision(_ request: AckRevisionRequest) async throws -> AckRevisionResponse
    }

    public enum InitialEnableScope: Sendable {
        case cloudSync
        case semanticIndex
    }

    public struct InitialEnableRequest: Sendable {
        let idempotencyKey: String // RFC4122 UUID
        let scope: InitialEnableScope
        let deviceID: UUID
        let platform: DevicePlatform
        let deviceSigningPublicKey: Data // decoded X9.63 P-256, exactly 65 bytes
        let deviceKeyAgreementPublicKey: Data // decoded X9.63 P-256, exactly 65 bytes
        let challengeID: UUID
        let proofSignature: Data // raw IEEE-P1363 r32 || s32, exactly 64 bytes
        let requestContextHash: Data // SHA-256, exactly 32 bytes
    }

    public protocol InitialEnableProviding: Sendable {
        func initialEnable(_ request: InitialEnableRequest) async throws -> BootstrapOperation
        func initialEnableStatus(operationID: UUID) async throws -> BootstrapOperation
    }

    public enum DeviceProofPurpose: Sendable {
        case register
        case keyDelivery
    }

    public struct DeviceProofChallengeRequest: Sendable {
        let deviceID: UUID
        let purpose: DeviceProofPurpose
    }

    public struct DeviceProofChallenge: Sendable {
        let challengeID: UUID
        let nonce: Data // raw challenge nonce; nonceDigest = SHA-256(nonce)
        let purpose: DeviceProofPurpose
        let deviceID: UUID
        let expiresAt: Date // RFC3339 UTC metadata; not cryptographic input
    }

    public protocol DeviceProofProviding: Sendable {
        func issueChallenge(_ request: DeviceProofChallengeRequest) async throws -> DeviceProofChallenge
    }

    public struct RegisterDeviceRequest: Sendable {
        let deviceID: UUID
        let platform: DevicePlatform
        let scope: InitialEnableScope // cloudSync for registration
        let deviceSigningPublicKey: Data // decoded X9.63 P-256, exactly 65 bytes
        let deviceKeyAgreementPublicKey: Data // decoded X9.63 P-256, exactly 65 bytes
        let challengeID: UUID
        let proofSignature: Data // raw IEEE-P1363 r32 || s32, exactly 64 bytes
        let requestContextHash: Data // SHA-256, exactly 32 bytes
        let idempotencyKey: String // RFC4122 UUID
    }

    public protocol DeviceEnrollmentProviding: Sendable {
        func registerDevice(_ request: RegisterDeviceRequest) async throws -> DeviceEnrollment
    }

    public protocol SupabaseAssetTransport: Sendable {
        func reserveAssetUpload(_ request: ReserveAssetUploadRequest) async throws -> AssetReservation
        func uploadCiphertext(_ reservation: AssetReservation, ciphertext: AsyncSequence<Data>) async throws
        func commitAssetUpload(_ request: CommitAssetUploadRequest) async throws -> CommitAssetUploadResponse
    }

    public struct AssetDownloadCapabilityRequest: Sendable {
        let assetID: UUID
        let itemID: UUID
        let audience: AssetDownloadAudience
    }

    public protocol AssetDownloadProviding: Sendable {
        func downloadCapability(_ request: AssetDownloadCapabilityRequest) async throws -> AssetDownloadCapability
    }

    public protocol SyncCoordinatorProtocol: Sendable {
        func enqueue(_ mutation: LocalMutation) async
        func drain(reason: SyncDrainReason) async
        func pause() async
        func resume() async
        func cancelGeneration() async
        func handleRevisionNotification(_ revision: Int64) async
    }

    public struct AccountKeyDeliveryRequest: Sendable {
        let deviceID: UUID
        let enrollmentGeneration: UUID
        let requestedKeyVersion: String // ASCII [A-Za-z0-9._-]{1,64}
        let challengeID: UUID
        let proofSignature: Data // raw IEEE-P1363 r32 || s32, exactly 64 bytes
        let requestContextHash: Data // SHA-256, exactly 32 bytes
        let idempotencyKey: String // RFC4122 UUID
    }

    public struct AccountKeyDeliveryEnvelope: Sendable {
        let deliveryID: UUID
        let keyVersion: String
        let ephemeralPublicKey: Data // decoded X9.63 P-256, exactly 65 bytes
        let nonce: Data // exactly 12 bytes
        let ciphertext: Data // exactly 32 bytes
        let tag: Data // exactly 16 bytes
        let aad: Data // exact v1 AAD bytes
        let expiresAt: Date // RFC3339 UTC metadata; not cryptographic input
    }

    public protocol AccountKeyMaterialProvider: Sendable {
        // The HTTP transport decodes POST /functions/v1/account-key-delivery
        // as AccountKeyDeliveryEnvelope. This provider uses the device
        // key-agreement private key in memory to decrypt that envelope, writes
        // the resulting key to secure storage, and returns AccountKeyMaterial.
        // The original account key exists remotely only in Vault; it never
        // appears in HTTP/logs/the delivery ledger.
        func obtainAccountKeyMaterial(_ request: AccountKeyDeliveryRequest) async throws -> AccountKeyMaterial
        func rotateAccountKey() async throws -> AccountKeyRotation
    }

    public enum DeletionScope: Sendable {
        case singleItem(UUID)
        case semanticIndex
        case allCloud
        case account
        case byokCredential
    }

    public struct DeletionRequest: Sendable {
        let idempotencyKey: String
        let scope: DeletionScope
    }

    public protocol CloudDeletionProviding: Sendable {
        func deleteItem(_ itemID: UUID) async throws -> MutationResult
        func requestDeletion(_ request: DeletionRequest) async throws -> DeletionJob
        func deletionStatus(jobID: UUID) async throws -> DeletionJob
    }

    public actor CloudDeletionCoordinator {
        init(transport: CloudDeletionProviding, idempotencyStore: DeletionIdempotencyStore)
        func deleteItem(_ itemID: UUID) async throws -> MutationResult
        func request(_ request: DeletionRequest) async throws -> DeletionJob
        func status(jobID: UUID) async throws -> DeletionJob
        func retry(jobID: UUID) async throws -> DeletionJob
    }

    public enum ReenableScope: Sendable {
        case cloudSync
        case semanticIndex
    }

    public struct ReenableRequest: Sendable {
        let idempotencyKey: String
        let scope: ReenableScope
        let expectedCloudGeneration: UUID?
        let expectedIndexingGeneration: UUID?
        let expectedResetFenceID: UUID?
        let terminalDeletionJobID: UUID
    }

    public protocol CloudReenableProviding: Sendable {
        func reenable(_ request: ReenableRequest) async throws -> ReenableOperation
        func reenableStatus(operationID: UUID) async throws -> ReenableOperation
    }

    public protocol ResetFenceProviding: Sendable {
        func pullResetFence(_ request: PullResetFenceRequest) async throws -> ResetFenceResponse
        func acknowledgeResetFence(_ request: AckResetFenceRequest) async throws -> ResetFenceAckResponse
    }

    public protocol BYOKCredentialManager: Sendable {
        func fingerprint() async throws -> String?
        func testCredential() async throws -> BYOKTestResult
        func replaceCredential(_ credential: UserSuppliedOpenRouterCredential) async throws
    }

    public enum CloudCapability: Sendable {
        case cloudSync
        case platformAI
        case byokAI
    }

    public protocol EntitlementAuthority: Sendable {
        func currentSession() async throws -> SupabaseSession
        func refreshEntitlement() async throws -> EntitlementSnapshot
        func require(_ capability: CloudCapability) async throws
        func appAccountToken() async throws -> UUID
    }

    public struct SemanticSearchRequest: Sendable {
        let query: String
        let filters: SemanticSearchFilters
        let limit: Int
    }

    public protocol CloudSemanticSearchProviding: Sendable {
        func search(_ request: SemanticSearchRequest) async throws -> SemanticSearchResponse
    }

    public protocol SensitiveContentGate: Sendable {
        func inspect(_ item: LocalClipboardItem) async -> PrivacyDecision
        func inspectQuery(_ query: String) async -> PrivacyDecision
    }

    public protocol MCPAuthorizationRevalidator: Sendable {
        func revalidateBeforeRemoteAwait(tool: MCPTool, itemIDs: [UUID]) async throws
        func revalidateAfterRemoteAwait(tool: MCPTool, itemIDs: [UUID]) async throws
    }

    public protocol CloudKitRecoverySource: Sendable {
        func importLatestEncryptedSnapshot() async throws -> CloudKitImportResult
        func freezeCloudKitWrites() async throws
        func recordLocalMigrationMarker(_ marker: CloudKitLocalMigrationMarker) async throws
        func recordCloudMigrationMarker(_ marker: CloudKitCloudMigrationMarker) async throws
        func markOverallMigrationComplete() async throws
    }

    public protocol EncryptedEnvelopeProvider: Sendable {
        func encrypt(_ plaintext: Data, aad: Data, keyVersion: String) throws -> CiphertextEnvelope
        func decrypt(_ envelope: CiphertextEnvelope, aad: Data) throws -> Data
    }

`CloudDeletionProviding` is a transport, not an owner. Exactly one shared
`CloudDeletionCoordinator` actor instance per installed app process owns
deletion request idempotency, retry, polling, and status observation. Settings,
BYOK, and account deletion flows receive that same actor and MUST NOT instantiate
their own coordinator or call the worker directly. Every remote MCP await is
bracketed by the two revalidation calls.

The `CloudReenableProviding` and `ResetFenceProviding` methods are transport
surfaces only; the SyncCoordinator actor owns reset-fence sequencing and the
single CloudDeletionCoordinator actor owns deletion sequencing. A
`ReenableRequest` MUST carry the expected generation(s), reset-fence ID, and
terminal deletion-job ID from the current owner snapshot; the server performs
the authoritative CAS while holding the profile/AI-state locks. Swift never
supplies a new generation, enrollment, or account key.
An implementation that passes a source-token test but does not exercise the
real macOS/iOS app path does not satisfy this contract.

The Swift `CloudSemanticSearchProviding` protocol calls only the authenticated
Edge endpoint and carries `SemanticSearchRequest`; it never exposes
`query_embedding` or calls `private.match_clipboard`. `DeviceProofProviding`,
`InitialEnableProviding`, and `DeviceEnrollmentProviding` call the
authenticated challenge/bootstrap/register-device Edge contracts; they never
call a device-registration Data API RPC or construct an enrollment
generation. `AccountKeyMaterialProvider` first obtains a single-use
`key_delivery` challenge, signs it with the registered device-signing P-256
private key, and calls `POST /functions/v1/account-key-delivery` while
`cloudSync` is active. It decrypts the returned envelope using the separate
device key-agreement private key in memory and writes the key only to
Keychain/secure storage; the original account key is never sent as a plain
response and exists remotely only in Vault.
After expiry it fails closed for a new device, while a previously cached key
remains available only to local decryption. Explicit deletion/destruction
remains a separate `CloudDeletionProviding.requestDeletion` cleanup operation:
account key destruction is only an `allCloud` or `account` job, and BYOK
destruction is only a `byokCredential` job. `replaceCredential` atomically
switches the BYOK reference and then destroys the old secret through that
worker; no protocol method may bypass the single DeletionWorker.

`SupabaseAssetTransport` retains the logical reserve/upload/commit method names
but its transport is the authenticated Edge signer flow above, never a direct
Data API reserve/commit RPC. The
`AssetDownloadProviding` transport calls the identity-only Edge download
capability endpoint; `api.export_encrypted` carries attachment metadata only.
`InitialEnableProviding` is the only initial bootstrap transport and
`CloudReenableProviding` is only for terminal-deletion re-enable. Swift never
constructs a server enrollment generation or receives a Storage service
credential.

## Compatibility and implementation prerequisites

Supabase Edge functions run in the Supabase Deno-compatible TypeScript
runtime/CLI and must be validated there. Node 22+ and TypeScript 5 are
prerequisites only for repository tools, the legacy gateway, or CI tooling that
actually runs on Node and uses supabase-js; they are not Edge runtime
requirements. If management tooling ever calls Supabase Management
OAuth /v1/oauth/token, any successful 2xx response is accepted; this is not a
StoreKit or Auth entitlement criterion. No Realtime schema change or extension
version pin is permitted. Schema migrations must make every Data API exposure,
GRANT, RLS policy, Storage bucket, and private relation explicit in review.

Model names, semantic-document field vocabulary, RRF constants, page sizes,
retry backoff values, and Storage object naming are candidates until the
bake-off/evidence gates pass. The fixed contract is 1024 dimensions, one active
identity, the three independent rank lists, and the privacy/entitlement
failure semantics.
