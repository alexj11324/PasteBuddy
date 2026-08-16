# Monetization, authentication, and entitlement contract

## Status

This is the WP0 target contract for Supabase-backed authentication and
commercial gates. It does not create products, configure StoreKit, or deploy an
Edge verifier. Existing local entitlement code is a migration input, not proof
that this contract is implemented.

## Account authority

Apple, Google, and Magic Link sign-in resolve to one Supabase user_id. V1
runtime targets macOS and iOS; Android and Web only consume the protocol.
No-account local mode remains complete for capture, local history, local search,
and local privacy controls.

For Apple platform purchases, StoreKit appAccountToken MUST equal the
Supabase UUID. The transaction verifier accepts the signed transaction,
validates product, environment, ownership, and signature, then persists only
normalized entitlement facts. Raw signed transaction payloads, payment details,
and billing credentials are never stored in PasteBuddy tables.

## Product capabilities

An active Cloud subscription grants encrypted cloud sync and platform AI through
the Supabase/OpenRouter path. An active BYOK Annual grants encrypted cloud sync
and use of the user-supplied OpenRouter credential, but does not grant platform
AI. Product identifiers and localized prices remain App Store configuration;
every entitlement row maps to independent capabilities:

| Capability | Source | Scope |
| --- | --- | --- |
| local | no account required | local capture/history/search; never proof of cloud access |
| cloud_sync | verified active Cloud subscription or verified active BYOK Annual | encrypted cloud sync, quota, cursor pull, and attachment upload/commit |
| platform_ai | verified active Cloud subscription only | platform OpenRouter AI and platform semantic retrieval/indexing |
| byok_ai | verified active BYOK Annual only | user-supplied OpenRouter Vault credential and BYOK semantic retrieval/indexing |
| dev_alpha | explicit non-production environment | development/alpha-only quotas and test products |

Free is for Dev/Alpha only. A Pro Supabase plan is required before formal
subscription launch. The account quota contract is 5,000 cloud clipboard items
and 250 MB cloud attachments. Local history is not capped by product count.

## Complete-set transaction handling

Every purchase, restore, and StoreKit transaction update MUST recompute the
complete set of currently valid transactions. A single expired, revoked, or
out-of-order transaction must not overwrite another valid subscription.
Entitlement state is derived from all valid normalized rows, with explicit
precedence for product capability and expiration.

The following are not entitlement authorities:

- a local simulated trial or installation-date flag;
- a cached semantic document or embedding;
- a local API key;
- a StoreKit product lookup without a verified transaction;
- a short-lived token issued by the old gateway.

There is no local trial bypass. An introductory offer is valid only when its
verified StoreKit transaction is active and the Edge verifier maps it to the
same cloud capability as the product.

Initial provisioning uses authenticated `POST /functions/v1/initial-enable`
with `{ idempotency_key, scope, device_id, platform,
device_signing_public_key, device_key_agreement_public_key, challenge_id,
proof_signature, request_context_hash }`. The Edge may perform a
non-authoritative cryptographic precheck, but the authoritative transaction
locks state and then checks the short-lived single-use `purpose=register`
challenge, unbound-or-same-user ID, byte-exact v1 signing proof, challenge CAS,
and consumption together. For cloud bootstrap it bind-if-absent creates the
initiating device row with both keys and server-mints enrollment; semantic
bootstrap requires an existing same-user non-revoked device and never replaces
its keys. Each scope may be initialized only once: cloud scope creates the
initial account-key version and cloud generation;
semantic scope requires an existing same-user non-revoked device and creates
the initial indexing generation and identity. No key
material is returned, and the initial backfill starts only after bootstrap
success and `POST /functions/v1/account-key-delivery`. A different idempotency
key or different proof after initialization fails closed. Later devices use
authenticated `POST /functions/v1/register-device` with platform, both public
keys, and the byte-exact v1 IEEE-P1363 proof,
and active `cloud_sync`; it is not a Data API RPC. Expired accounts cannot
register or recover a key.

## Expiry and lock semantics

At subscription expiry, revocation, account suspension, or failed entitlement
refresh, `cloud_sync`, `platform_ai`, and `byok_ai` become false immediately.
Cloud writes, platform AI, BYOK AI, and **all remote Vault secret
retrieval/use** lock immediately. Local capture/history/search and local
decryption with an already cached account data key remain available. Existing
local data and already converged cloud data are not deleted solely because a
subscription expired.

Capability checks are operation-specific: sync push/upsert and asset
reserve/commit require `cloud_sync`; owner-scoped `pull_changes` and
`ack_revision` require only a valid identity session plus enabled-state,
generation, fence, and RLS checks. The authenticated semantic-search Edge
endpoint requires `platform_ai` or `byok_ai` and rechecks the chosen capability
after every provider await; platform and BYOK Vault use require their matching
AI capability. Remote account-key retrieval for a new device requires
`cloud_sync`, so an expired device cannot recover the account key from Vault.
Explicit authenticated cloud-data deletion and Vault-secret destruction remain
available as cleanup operations after expiry; they do not retrieve or use a
secret and do not restore any capability.

An Edge/RPC call checks current Supabase entitlement for the operation. The old
fixed-ten-minute gateway JWT is not a target design. A Supabase identity JWT
continues to authenticate the user after commercial expiry and permits
owner-scoped login, read/export, deletion, and cleanup; it does not grant
cloud_sync, AI, Vault, or BYOK use. Operation capability assertions are
short-lived, rechecked before and after every remote await, and never remain
valid beyond the entitlement check that authorized that operation.

When a transaction update is processed while another valid transaction exists,
the valid transaction remains effective. The verifier must expose enough
normalized facts for a complete-set recomputation and must never use last-write
arrival order as the capability decision.

## Account recovery key and BYOK Vault separation

The AES-256-GCM account data encryption key is not a BYOK credential. Supabase
Vault creates/authorizes the key flow and stores the recovery copy;
api.account_keys stores key_version, rotation_status, and non-secret metadata.
An authenticated authorized device may receive actual account-key material
only through `POST /functions/v1/account-key-delivery` while `cloud_sync` is
active and stores it in Keychain or secure storage. The service can recover it.
Rotation creates and
activates a new version while the old version becomes retiring and remains
decryptable/recoverable. Only after reencryption, required device
acknowledgements, and a safe rotation gate may the old reference be
revoked/deleted. A new device is denied remote account-key recovery after
expiry; subscription expiry does not erase key material already cached
locally. Account-key delivery requires a valid identity, active `cloud_sync`,
owner/non-revoked device, current enrollment and reset ACK, and a single-use
`key_delivery` signing-key proof. The Edge uses the registered key-agreement
public key plus ephemeral P-256 ECDH, HKDF-SHA256, and AES-256-GCM with AAD
bound to the user, device, enrollment, key version, challenge, and delivery
ID. It responds with only a no-store device-bound envelope (ephemeral ECDH
public key, nonce, ciphertext, tag, AAD, and expiry). The original account
key exists remotely only in Vault; it never appears in HTTP, logs, or the
delivery ledger. The in-memory envelope is never logged or
persisted. Active/authorized-
retiring versions may be delivered, but revoked versions, replayed
challenges, stale enrollment, wrong device, version mismatch, and expiry fail
closed. The client decrypts in memory and writes only to Keychain/secure
storage; separate signing and key-agreement private keys are held in Secure
Enclave or, when unavailable, Keychain-protected storage.
Account-key deletion happens only with all-cloud/account deletion after
ciphertext cleanup is verified. All-cloud/account reset first bumps
`cloud_generation`, disables cloud processing, installs fences, invalidates old
device cursors/pending outboxes, and rejects old-generation writes. The old key
remains available until ciphertext, Storage, derived data, and sync-payload
cleanup is verified; only then are the account key and BYOK secret deleted.
Local history is retained. Only first-ever cloud enable may run the automatic
full compliant backfill; explicit re-enable after all-cloud/account reset must
create a new account key/generation/enrollment and never auto-backfill reset-time
history. A device
reconnecting after that reset must pull and ACK the reset fence after isolating
pre-reset outbox rows and recording its local counter floor; the server rejects
push until server re-enrollment and accepts only counters above the effective
floor. Reset-time local history never auto-backfills.

The only post-deletion re-enable contract is `POST /functions/v1/re-enable` with a durable
idempotency key, scope, expected cloud/indexing generation(s), expected
reset-fence ID, and terminal deletion-job ID. Cloud re-enable requires an
active `cloud_sync` capability and atomically creates a new account-key version
plus cloud generation. AI re-enable requires `platform_ai` or `byok_ai` and
atomically creates a new indexing generation plus active embedding identity.
The server locks state and returns `REENABLE_PRECONDITION_FAILED` for a delayed
request whose deletion terminal state, intent, fence, or generation changed.
Both return an operation/status ID and fail closed while deletion is
nonterminal.

The client submits a user-supplied OpenRouter key over the authenticated BYOK
flow. The service stores the raw secret in Supabase Vault and api.ai_profiles
stores only fingerprint and status. The client may display the fingerprint and
request test, replacement, or destruction but never reads the secret back. The
only opaque Vault reference is private.vault_secret_refs.vault_secret_ref:
account_data_key rows require account_key_id and rotate one active reference per
account-key version; byok_openrouter_key has a null account_key_id and at most
one active reference per user.

V1 rejects custom URLs, arbitrary hosts, provider selection, and independent
document/embedding endpoints. This OpenRouter-only rule removes the prior
custom-http-URL leakage path. A missing Vault secret, revoked key, malformed
fingerprint, or policy mismatch fails closed.

Deleting a BYOK credential immediately disables and destroys that Vault secret
and fingerprint without deleting other cloud data or the account recovery key.
This uses the authenticated `POST /functions/v1/deletion-request` endpoint with
scope `byok_credential`; all-cloud, semantic-index, and account deletion use
the same endpoint, with status from
`GET /functions/v1/deletion-status?job_id=...`. These cleanup operations require
a valid Supabase auth session but remain available after subscription/entitlement
expiry without requiring `cloud_sync`; an expired or invalid JWT is denied and
they never retrieve or use a remote secret.

Platform and BYOK requests require OpenRouter provider.zdr=true and
data_collection=deny. A provider/embedding allowlist probe verifies both flags
for the selected route. If a zero-retention endpoint cannot be verified, the
request fails closed instead of silently falling back; BYOK cannot bypass the
retention policy.
Platform and BYOK embeddings both remain fixed at 1024 dimensions, with one
active embedding identity per account.

## Required Supabase records

The normalized entitlements, account-key metadata, BYOK fingerprint, and usage counters are
described in SUPABASE_SCHEMA_API_CONTRACT.md. RLS and RPCs derive user_id from
the Supabase JWT and re-check the current entitlement. api tables have no
direct authenticated CRUD exposure in V1; approved api RPCs are the Data API
allow-list. Asset reserve/commit are not Data API RPCs: authenticated Edge
endpoints authorize private metadata first and use the Edge Storage service
client to sign exact private objects. `api.export_encrypted` returns attachment
metadata only; a separate valid-identity Edge endpoint signs a short-lived
download bearer URL, including after commercial expiry. The public schema does
not contain PasteBuddy business tables.

Supabase Edge functions run in the Supabase Deno-compatible TypeScript runtime.
Node 22+ and TypeScript 5 apply only to repository Node tooling, the legacy
gateway, or CI dependencies that actually use supabase-js. If management
tooling later invokes Supabase Management OAuth /v1/oauth/token, any successful
2xx response is accepted; this is not a StoreKit/Auth entitlement rule.

## Verification and migration gates

The implementation must prove all of the following in a real macOS/iOS
runtime, not only through source-token tests:

- sign in through each supported account path and bind StoreKit
  appAccountToken to the Supabase UUID;
- purchase, restore, reorder, expire, and revoke transactions while preserving
  another valid transaction;
- show no local-trial route and lock cloud/AI/Vault at expiry;
- store an OpenRouter key in Vault while exposing only its fingerprint;
- reject custom provider URLs and fail closed when ZDR is unavailable;
- preserve full local history in no-account/offline mode.

Static source tests and fake entitlement objects are intermediate evidence.
They cannot establish runtime identity, server verification, or expiry behavior.
