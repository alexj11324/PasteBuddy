# Supabase domain and PowerSync boundary contract

## Status and scope

This is the WP0 minimum domain freeze for the PowerSync/Supabase migration.
It is documentation only. It creates no table, migration, Edge Function,
Storage bucket, Vault secret, PowerSync project, or Swift adapter.

V1 client and runtime acceptance is macOS+iOS only. Android and Web are
reserved in the service protocol and tenant model for a later decision; they
are not implemented here and cannot count toward WP1-WP7 completion.

Implementation scope and order are controlled only by the
[Cloud Sync and AI Refactor Plan](PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md).
This document remains authoritative for domain data and business boundaries;
the acceptance matrix remains authoritative for proof.

PowerSync owns local replication mechanics and its local SQLite database is the
client read authority. Supabase owns Auth, tenant policy, Postgres rows,
private Storage, Edge actions, and fixed server jobs. RevenueCat owns purchase
normalization; Supabase entitlements are the cloud authorization truth.

SDK callback behavior, upload ordering, conflict semantics, concurrency,
attachment helper behavior, and platform runtime results are deliberately
unverified. They belong to WP1 and WP4/WP5 evidence. This document does not
define an executable concurrency protocol.

## Boundary principles

- Every cloud row is owned by one Supabase Auth user ID. RLS policies use the
  authenticated user, never a client-supplied tenant claim.
- Direct table CRUD is not a client contract. The PowerSync upload boundary
  and authenticated Edge actions validate business input, apply RLS, quotas,
  and the fixed deletion rules.
- The local PowerSync SQLite database is the only source used by UI, offline
  search, and local pending work. A remote response is not a UI cache.
- Sensitive or user-excluded content is rejected before handoff, upload, or
  AI processing. It has zero network path.
- Cloud content is service-readable under tenant policy. This is not E2EE.
  Supabase-managed TLS, Storage privacy, and encryption at rest are platform
  controls; WP0 adds no bespoke content or device cryptography.
- The API exposes business actions and responsibility. It does not freeze
  SDK callback signatures, retry choreography, or a custom wire protocol.

## Minimum domain tables

Only these eight business tables are frozen by WP0.

| Table | Required fields and responsibility |
| --- | --- |
| profiles | id = Auth user ID; cloud_epoch; cloud_enabled; account_status; created_at; updated_at. One tenant lifecycle owner. |
| entitlements | id; user_id; revenuecat_app_user_id; entitlement_key; product_id; status; expires_at; verified_at; updated_at. Normalized RevenueCat facts, never a raw receipt authority. |
| clipboard_items | id; user_id; client_mutation_id; content_kind; service-readable cloud content or metadata; source metadata; cloud_epoch; created_at; updated_at; deleted_at. Sensitive/excluded rows never enter this table. |
| assets | id; user_id; item_id; private_storage_path; content_type; byte_count; content_hash; cloud_epoch; created_at; updated_at; deleted_at. Bytes live only in private Storage. |
| semantic_documents | id; user_id; item_id; redacted_document; semantic_fts; embedding = pgvector halfvec(1024); embedding_identity; embedding_dimensions = 1024; index_state; created_at; updated_at; deleted_at. Service-visible derived data, never raw sensitive content. |
| ai_profiles | user_id; provider = OpenRouter; policy_version; active_embedding_identity; embedding_model; embedding_dimensions = 1024; byok_fingerprint; byok_status; server-only opaque_vault_credential_ref; updated_at. No raw BYOK key; the reference is never synced to or returned to a client. |
| deletion_requests | id; user_id; scope; target_id; client_mutation_id; status; requested_at; completed_at; verification_summary; error_code. Fixed deletion intent and observable result. |
| usage_counters | user_id; period_start; period_end; cloud_items_used; attachment_bytes_used; ai_requests_used; updated_at. Quota and usage accounting. |

Physical indexes, generated columns, PowerSync internal tables, queue
metadata, and provider-specific implementation fields remain open to WP1.
The service may add operational metadata only when it does not change the
business ownership or privacy contract.

## Frozen field semantics

### Tenant and RLS

The tenant key is profiles.id and the user_id on every other table. Every
table has RLS enabled with deny-by-default policies. Authenticated reads and
writes are limited to auth.uid() = user_id and to the named business action.
The public schema has no PasteBuddy business surface. Private Storage is not
publicly listable; object paths are owner-scoped and issued through the
approved Edge/helper path.

### client_mutation_id

This is an opaque client action identifier used to make a repeated user
action observable and idempotent within one tenant and action scope. A retry
with the same identifier must return the same business outcome; a conflicting
payload is an explicit error. It is not a mutation DSL, a device counter, a
receipt, or a synchronization cursor. The final uniqueness scope and
PowerSync adapter mapping are WP1/WP4 decisions.

### deleted_at

The server sets deleted_at as the durable deletion marker before removing
payloads or derived rows. PowerSync must not re-expose a row after the
authoritative deletion result, and a stale upload must not resurrect it.
Retention/compaction is service-owned and only follows the fixed deletion
verification gate. The client never invents a tombstone protocol.

### cloud_epoch

profiles.cloud_epoch is an opaque server-generated lifecycle value. A
server-side action rejects a request that belongs to a prior tenant epoch.
Clients may hold the value for diagnostics and reconnect, but may not derive
ordering, counters, fences, cursors, or conflict policy from it.

### Local/cloud identity and account lifecycle

PowerSync SQLite is the sole runtime local authority before and after login.
The legacy GRDB database is read-only migration input. Sync-disabled mode,
no-account mode, sensitive content, and excluded content remain local-only and
never enter clipboard_items. A synced row and its local pending form are
coalesced to one visible item; the newest local capture wins until its cloud
outcome is known.

Logout clears only the current account's downloaded cache. It does not delete
cloud rows or local-only history. After the user completes login to account B,
and before any PowerSync connect, backfill, or cloud upload, the app confirms
the eligible project count and attachment bytes. A rejected confirmation leaves
the data local-only. The same local item in two accounts gets separate
deterministic account-scoped cloud IDs.

Eligible backfill includes all product-retained, policy-compliant history,
including pinned items, ordered by max(createdAt, updatedAt) descending. It
uses batches of 100, checkpoints after each upload before selecting the next
batch, and resumes from that checkpoint after pause, quit, relaunch, quota
release, or subscription recovery.

### PowerSync SQLite logical responsibilities

The same PowerSync-managed SQLite database carries three logical
responsibilities; these are not three databases or competing authorities:

- local-only history (`local_clipboard_items`): no-account, sync-disabled,
  sensitive, excluded, and otherwise local history;
- synced cloud replica (`clipboard_items`): server-approved tenant rows only;
- local upload/backfill/error state (`local_upload_state`): pending work,
  checkpoint, permanent rejection, and visible local-only error state.

The names in parentheses are logical responsibilities, not a WP0 physical-table
freeze. WP1 verifies the formal adapter's physical mapping while preserving one
PowerSync SQLite authority.

### Quota

Each tenant is limited to 5,000 cloud clipboard items and 250,000,000 bytes of
cloud attachments. A quota failure blocks new cloud uploads only. Local
history, offline search, existing cloud rows, and a resumable continuation
remain available. usage_counters are accounting evidence, not a client
authorization shortcut.

### AI and BYOK

OpenRouter is the only V1 provider route. Platform and BYOK requests require
verified provider zero-data-retention policy: provider.zdr=true and
data_collection=deny. A failed policy probe fails closed. Qwen3 Embedding is
the default candidate at 1024 dimensions. Each tenant has one active
embedding_identity; an identity change makes old derived rows stale and
requires a resumable rebuild.

The raw user OpenRouter key is stored only in Supabase Vault. The server keeps
an opaque Vault credential reference/mapping and ai_profiles stores a
fingerprint and status; neither the reference nor raw key is visible to a
client or PowerSync stream. BYOK never grants platform AI. Vault access is
owned by the authenticated server boundary.

### Fixed deletion

Allowed scopes are item, semantic_index, all_cloud, account, and
byok_credential. The fixed process is:

1. Authenticated user confirmation creates or returns one idempotent deletion
   request.
2. For all_cloud, the server increments cloud_epoch and closes cloud writes
   before cleanup.
3. The fixed all_cloud order is semantic/vector, Storage, clipboard, AI
   profile, then Vault. Each class has a negative query; success requires all
   deletable cloud content/AI/asset/domain rows to be empty, while normal-login
   profiles/entitlements and deletion-request/status/audit metadata remain.
   Storage, vector, semantic, and Vault checks must still be zero. Account
   deletion, not all_cloud, clears the account scope.
4. For item scope, deleted_at is durable before asynchronous Storage and
   semantic/vector cleanup; stale devices cannot resurrect the item.
5. A stale epoch or old AI/asset work cannot commit. BYOK or account data is
   removed only after the relevant cleanup verification.

Statuses are requested, running, succeeded, or failed. This bounded set is
not an arbitrary phase machine, and changing only status cannot complete
cleanup. Settings observes status through the owner boundary; retries cannot
recreate deleted content. A valid authenticated session may request deletion
after commercial expiry, but an invalid session is denied.

### Permanent queue settlement

Permanent quota and policy rejections are settled from the PowerSync queue and
become visible local-only errors. They cannot retry forever or block later
items. Temporary freeze and the concrete SDK settlement callback are WP1
proof items; WP0 does not invent a callback or queue protocol.

## PowerSync upload/download ownership

| Business action | Input responsibility | Owner and output responsibility |
| --- | --- | --- |
| Connect tenant | Authenticated Supabase session and current user ID | Main app's single PowerSync connect owner; local SQLite becomes readable only for that tenant. |
| Upload domain change | Local row change, client_mutation_id, current cloud_epoch, and privacy decision | PowerSync upload adapter plus Supabase RLS/Edge validation; returns accepted, duplicate, quota, policy, or deletion status and settles permanent failures visibly. |
| Download domain change | Authenticated tenant and SDK-managed replication request | PowerSync download path applies server-approved rows to its SQLite database; UI observes only local state. |
| Upload asset | Item ownership, content type, size, hash, and current quota | WP1 chooses a formal SDK helper or exact-object signed URL fallback; Supabase verifies owner, size, hash, and quota before commit. |
| Semantic index/search | Eligible item IDs and query after local privacy gate | WP5 owns Edge/OpenRouter/pgvector implementation; returns derived IDs/ranks and status, never a sensitive payload. |
| Request deletion | Fixed scope, target ID, client_mutation_id, authenticated session | Supabase Edge and one fixed worker execute the bounded process and return observable status. |
| Switch account | Explicit user confirmation and old/new Auth identities | Main app stops the old connection and creates a separate tenant session; rows are never merged. |

These are responsibility statements, not endpoint or SQL signatures. Exact
PowerSync upload/download APIs, transaction boundaries, conflict behavior,
attachment helper choice, and retry semantics must be demonstrated in WP1 and
WP4 before being treated as correct.

## Exposure and secret rules

- Supabase Auth is the only identity source for tenant RLS.
- RevenueCat CustomerInfo is reconciled before Supabase entitlement updates;
  entitlements, not a local flag, authorize cloud actions.
- Edge Functions may call fixed server jobs and private Storage operations.
  Supabase Queues/Cron may wake those jobs, but WP0 does not claim delivery
  semantics.
- Vault stores the raw BYOK secret only. A server-only opaque Vault reference
  may map that secret from ai_profiles/private service metadata; no client
  receives the reference. No domain table stores a key, device proof, ECDH
  material, HMAC receipt, or server-recoverable AES-GCM envelope.
- Sentry receives bounded diagnostics and identifiers only; no clipboard
  payloads, tokens, keys, or sensitive query text.
- No anonymous path can read or write tenant data.

## Explicit non-contracts

WP0 does not design or freeze a self-developed mutation DSL, push/pull
protocol, revision, cursor, counter, reset fence, HMAC receipt, generic
deletion lease protocol, device proof, ECDH exchange, or custom cryptographic
envelope. It does not claim that a PowerSync Swift SDK, Supabase adapter,
Storage helper, queue, or RevenueCat integration behaves correctly. Those
claims require the WP1 hard-stop PoC and later runtime evidence.

References: [PowerSync](https://docs.powersync.com/),
[Supabase Auth](https://supabase.com/docs/guides/auth),
[Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security),
[Supabase Storage](https://supabase.com/docs/guides/storage),
[Supabase Edge Functions](https://supabase.com/docs/guides/functions),
[Supabase Queues](https://supabase.com/docs/guides/queues),
[RevenueCat](https://www.revenuecat.com/docs/), and
[OpenRouter ZDR](https://openrouter.ai/docs/features/zdr).
