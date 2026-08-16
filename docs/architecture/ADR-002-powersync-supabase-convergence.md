# ADR-002: PowerSync and Supabase cloud convergence

## Status and scope

Accepted as the new WP0 architecture decision on 2026-08-16. This is a
decision and gate document, not an implementation protocol. It freezes
ownership, privacy, service boundaries, quotas, and the order of evidence.
PowerSync SDK behavior, Swift adapter behavior, concurrency behavior, hosted
configuration, and runtime results remain unverified until the named gates.

Normative terms are MUST and SHALL. A document statement is not evidence that
code, an account, a Supabase project, or a third-party service is configured.

The [Cloud Sync and AI Refactor Plan](PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md)
is the sole authority for implementation scope and order. This ADR remains
authoritative for architecture decisions; the schema contract owns data
boundaries and the acceptance matrix owns proof.

## Context

The previous ADR made PasteBuddy responsible for a general synchronization
protocol, reset recovery, generic deletion, and device cryptography. Those
boundaries were too large to prove safely in a documentation-only WP0 and
duplicated capabilities already provided by a local-first replication SDK and
managed backend services. A smaller architecture must keep local behavior
complete while making the cloud boundary observable and replaceable.

## Decision

### Local ownership and tenant boundary

1. PowerSync is the local-first replication layer. Its managed, encrypted
   SQLite database is the single runtime local authority before and after
   login for UI reads, offline lexical search, and pending cloud work. There
   is no long-term second database or snapshot that can drive the UI. Legacy
   GRDB is read-only migration input.
2. The main macOS/iOS app owns exactly one authenticated PowerSync connection
   and one connect/disconnect lifecycle per process. Settings, background
   tasks, and views receive that owner; they do not create connections.
3. Extensions never connect to PowerSync or Supabase. After the existing
   privacy decision, an extension writes an encrypted App Group handoff. The
   main app imports that handoff into the local PowerSync database. The exact
   handoff adapter and key access are WP1/WP4 evidence, not a new crypto
   protocol.
4. A device with no account remains fully usable in local-only mode: capture,
   local history, local search, privacy controls, and local paste behavior do
   not require Auth, PowerSync Cloud, or a network. Sync-disabled, sensitive,
   and excluded content is local-only and never enters a synced table.
5. V1 runtime and acceptance scope is macOS+iOS. Android and Web are reserved
   in the service protocol and tenant model for a later decision; they are not
   implemented here and cannot count toward WP1-WP7 completion.
6. Every cloud row is tenant-scoped by Supabase Auth user ID. RLS is the
   server authority for tenant isolation. cloud_epoch is an opaque
   server-managed tenant lifecycle value used to reject stale cloud work; it
   is not a client revision, cursor, counter, or fence protocol.

### Managed service choices

| Concern | Decision | Official reference |
| --- | --- | --- |
| Local-first sync | PowerSync SDK and its SQLite replication model | [PowerSync docs](https://docs.powersync.com/) |
| Identity | Supabase Auth | [Supabase Auth](https://supabase.com/docs/guides/auth) |
| Data and tenant policy | Supabase Postgres with RLS | [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) |
| Attachments | Private Supabase Storage with owner-checked access | [Supabase Storage](https://supabase.com/docs/guides/storage) |
| Semantic index | Supabase Postgres plus pgvector | [Supabase vector columns](https://supabase.com/docs/guides/ai/vector-columns) |
| Server actions | Supabase Edge Functions | [Supabase Edge Functions](https://supabase.com/docs/guides/functions) |
| Durable server work | Supabase Queues and Cron for fixed jobs | [Supabase Queues](https://supabase.com/docs/guides/queues), [Supabase Cron](https://supabase.com/docs/guides/cron) |
| Purchases | RevenueCat customer and entitlement service | [RevenueCat docs](https://www.revenuecat.com/docs/) |
| Hosted AI | OpenRouter route with verified ZDR policy | [OpenRouter ZDR](https://openrouter.ai/docs/features/zdr) |
| Diagnostics | Existing Sentry integration; no new telemetry vendor | [Sentry Apple SDK](https://docs.sentry.io/platforms/apple/) |

PowerSync owns replication mechanics. Supabase owns Auth, Postgres policy,
Storage, Edge actions, and server jobs. RevenueCat owns purchase
normalization; Supabase stores the resulting entitlement truth for cloud
authorization. No WP0 statement claims an SDK callback, queue delivery
guarantee, or provider policy has been verified.

V1 does not adopt Supabase `gte-small`: its English-first behavior and
long-text truncation do not match the Chinese retrieval target. Qwen3 Embedding
at 1024 dimensions remains the default candidate pending the fixed bake-off;
this is a model choice, not a new model protocol.

### Privacy and content policy

The client privacy gate runs before an item enters an extension handoff,
PowerSync upload, attachment upload, or AI request. Sensitive content and
user-excluded content have zero network path: they remain local and are never
sent to PowerSync, Supabase, OpenRouter, or Sentry. A failed or unavailable
gate fails closed.

Cloud content is service-readable under Supabase Auth, RLS, and private
Storage. This architecture is explicitly not E2EE. TLS and provider-managed
encryption at rest are expected platform controls; WP0 does not invent a
client envelope, device proof, or recoverable cloud-key protocol.

Changing accounts requires an explicit confirmation. The app must stop the
current tenant connection, keep tenant data separated, and never merge one
user's local or cloud rows into another user's tenant. The confirmation UX and
relaunch behavior are WP6 acceptance items.

After the user completes account-B login, and before any PowerSync connect,
backfill, or cloud upload, the confirmation shows the eligible project count and
attachment bytes. Rejection keeps the data local-only.
A local item present in multiple accounts uses a deterministic account-scoped
cloud ID. Synced and local-only views of the same logical item are coalesced
to one visible row, with the newest local capture taking precedence until its
cloud outcome is known. Logout clears only the current account's downloaded
cache; it does not delete cloud data or local-only history.

### Backfill and quotas

After a successful first cloud enable, all policy-compliant history retained
by the product, including pinned items, is eligible. Items are ordered by
max(createdAt, updatedAt) descending and uploaded in batches of 100. Each
batch checkpoints after upload before the next batch is selected; pause,
quit, relaunch, and resume continue from that checkpoint. Quotas are 5,000
cloud clipboard items and 250,000,000 cloud attachment bytes per account.
Quota exhaustion stops new cloud uploads, preserves local history and existing
cloud rows, and resumes from the checkpoint after quota release or subscription
recovery. A permanent quota or policy rejection is settled from the PowerSync
queue as a visible local-only error; it cannot retry forever or block later
items. Exact SDK settlement and continuation behavior is WP1/WP4 evidence.

### Fixed deletion boundary

Deletion is a small fixed set of business actions, not a general client
protocol or arbitrary phase machine:

1. The user confirms a scope and the authenticated app creates or returns one
   idempotent deletion request.
2. For all-cloud, cloud_epoch increments and cloud writes close before cleanup.
3. The fixed all-cloud order is semantic/vector, Storage, clipboard,
   AI-profile, then Vault. Each class has a negative query; success is
   impossible until all deletable cloud content/AI/asset/domain rows are empty.
   Normal-login profiles/entitlements and deletion-request/status/audit metadata
   remain for `all_cloud`; Storage, vector, semantic, and Vault checks are zero.
   Account deletion, not `all_cloud`, clears the account scope. Old-epoch AI or
   asset work cannot commit.
4. For item deletion, deleted_at is durable before asynchronous Storage and
   semantic/vector cleanup; stale devices cannot resurrect the item.
5. Status remains visible until verified success or an actionable failure.
   Retries are idempotent; changing only status never completes cleanup.

Supported scopes are item, AI index, all cloud data, account, and BYOK
credential. Their order and verification evidence are fixed by the schema
contract and WP1/WP6; no client-visible claim/lease/fence or custom deletion
DSL is introduced.

### CloudKit, Iroh, and edition boundary

CloudKit is used once as a latest encrypted snapshot recovery source. The
client imports it into local PowerSync SQLite, then permanently freezes
CloudKit writes before cloud upload. CloudKit is read-only recovery for 90
days; any later deletion is a separate explicit user action. There is no
dual-write period.

The existing Iroh implementation and data remain intact, but the shared
Iroh capability stays disabled on macOS, iOS, and extensions.

At the first 100 real Cloud users, the Coordinator runs a Cloud Edition versus
Open Edition gate. Open Edition is source-available, not an OSI full-stack
open-source claim. The gate records operational cost, privacy incidents,
support load, reliability, retention evidence, and local-only usability, then
makes a documented product decision. Neither edition receives an unverified
promise of cloud availability before that gate.

## Explicitly rejected in the target

PasteBuddy will not own a generic push/pull protocol, revision or cursor
scheme, client counters or reset fences, an application-specific mutation DSL,
HMAC receipts, device proof/ECDH, server-recoverable AES-GCM envelopes, or a
generic deletion phase machine. These names may occur in historical documents
only as rejected designs. The service and SDK must be exercised before any
replacement behavior is stated as correct.

## Work packages and governance

The stack is eight layers, in order:

1. codex/pb-cloud-architecture
2. codex/pb-powersync-poc
3. codex/pb-supabase-domain
4. codex/pb-revenuecat-auth
5. codex/pb-powersync-client
6. codex/pb-cloud-ai
7. codex/pb-cloud-migration-ui
8. codex/pb-cloud-release

The Coordinator owns the Gate definition, evidence review, and commit
checkpoint for each layer. Implementation defaults to Luna Max. One Sol agent
may perform one concentrated independent review; the same responsibility
boundary is escalated to Sol only after Luna has failed twice with evidence.
There is one writer per responsibility boundary. gh stack commands are
non-interactive and must use explicit branch/stack arguments; if gh stack
returns exit 9, stop and report the unsupported workflow rather than silently
using another one.

## WP0 non-goals and open evidence

WP0 does not add code, migrations, Supabase resources, secrets, hosted queues,
PowerSync configuration, SDK adapters, or tests. WP1 is the hard-stop PoC:
formal macOS+iOS Swift SDK adapter, fail-closed local encryption/Keychain,
App Group handoff, one connect owner, read-only old-GRDB migration,
account A/B isolation, quota/backfill, process-kill/reconnect/duplicate
behavior, and attachment handling must pass before PowerSync migration
continues. Unknown SDK semantics, concurrency behavior, and service limits
remain explicitly open until that evidence exists.
