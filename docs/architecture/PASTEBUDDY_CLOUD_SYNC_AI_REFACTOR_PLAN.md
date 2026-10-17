# PasteBuddy cloud sync and AI refactor plan

## Authority and outcome

This is the single authoritative implementation plan for the PowerSync,
Supabase, RevenueCat, and Cloud AI refactor. It controls scope and work
package order. It is a WP0 planning artifact, not evidence that any gate has
passed.

The target outcome is a local-first PasteBuddy that remains complete with or
without an account. One PowerSync-managed SQLite database is the only runtime
local authority in both states; there is no long-term second database. It adds
tenant-scoped cloud sync and optional AI without sending sensitive or excluded
content over the network.

V1 runtime and acceptance scope is macOS+iOS. Android and Web are reserved in
the service protocol and tenant model for a later decision; this plan does not
implement them and they cannot count toward WP1-WP7 completion.

The architecture decision is authoritative in
[ADR-002](ADR-002-powersync-supabase-convergence.md). The minimum data
boundary is authoritative in
[SUPABASE_SCHEMA_API_CONTRACT](SUPABASE_SCHEMA_API_CONTRACT.md). Proof,
evidence, and stop conditions are authoritative in
[SUPABASE_ACCEPTANCE_MATRIX](SUPABASE_ACCEPTANCE_MATRIX.md). Those documents
must not be silently replaced by this plan:

- this plan controls scope, order, ownership, and escalation;
- ADR-002 controls architecture decisions;
- the schema contract controls domain data and business boundaries;
- the acceptance matrix controls falsifiable proof.

## Target architecture and boundary

- PowerSync owns local-first replication and its SQLite database is the only
  UI, offline-search, and pending-work read authority.
- The main macOS/iOS app owns one PowerSync connection. Extensions never
  connect; they write only an encrypted App Group handoff for the main app.
- No-account mode is fully local. Account switching requires confirmation and
  never merges tenants.
- Supabase Auth, Postgres/RLS, private Storage, pgvector, Edge Functions,
  Queues, and Cron provide the cloud boundary. RevenueCat is the purchase
  identity/reconciliation boundary. OpenRouter ZDR is the hosted AI policy;
  existing Sentry remains the diagnostics boundary.
- V1 server actions use Deno/TypeScript Edge Functions. There is no standalone
  Rust backend. A Rust-to-Wasm evaluation requires a separately approved task,
  profiling evidence for a pure-compute bottleneck, and a benchmark showing
  that TypeScript misses a frozen latency or cost Gate.
- Sensitive and user-excluded content has zero network path. Cloud content is
  service-readable under Auth/RLS and is not E2EE.
- Cloud quotas are 5,000 clipboard items and 250,000,000 attachment bytes.
  Initial backfill prioritizes the newest 100 eligible items, then continues
  resumably.
- PowerSync Cloud is the sync service for Dev/Alpha; Prod uses an independent
  Supabase, PowerSync, and RevenueCat configuration.
- Deletion uses the fixed bounded business process. After the PowerSync
  migration, CloudKit is a one-time recovery import and read-only for 90 days.
  Until then, clipboard sync uses the encrypted CloudKit snapshot path. Iroh
  has been removed.
- At 100 real Cloud users, the Coordinator makes the documented Cloud Edition
  versus Open Edition decision using the agreed operational and privacy
  evidence.

The exact fields, tenant rules, client_mutation_id, deleted_at, cloud_epoch,
PowerSync upload/download responsibility, AI/BYOK boundary, and deletion
scopes remain in the schema contract. This plan does not define a new sync
protocol, crypto wire format, or concurrency machine.

## Account, local-only, and backfill rules

- PowerSync SQLite is the only local authority before and after login. The
  legacy GRDB store is read-only migration input and never a long-term second
  database.
- Sync disabled, no account, sensitive content, and excluded content remain
  local-only and never enter a synced table. A synced and local-only view of
  the same logical item appears once; the local capture wins until its cloud
  outcome is known.
- Logout clears only the current account's downloaded local cache. It does not
  delete cloud data or local-only history.
- After the user completes login to account B, and before any PowerSync
  connect, backfill, or cloud upload, a confirmation shows the eligible project
  count and attachment bytes. Rejecting keeps the history local-only. A local
  item entering two accounts receives separate deterministic account-scoped
  cloud IDs.
- Backfill includes all policy-compliant history retained by the product,
  including pinned items, ordered by max(createdAt, updatedAt) descending.
  Batches contain 100 items; each batch must checkpoint after upload before
  the next is selected. Pause, quit, relaunch, and resume continue from that
  checkpoint. Quota release or subscription recovery resumes from it.
- Permanent quota or policy rejection is settled from the PowerSync queue and
  becomes a visible local-only error; it cannot retry forever or block later
  items. Temporary freeze and its observable result are a WP1 SDK gate, not a
  new queue protocol.

## Ordered work packages and gates

Every work package begins only after the prior focused checkpoint is reviewed.
In WP0 all statuses are Not run. A build, source scan, fake service, or
document review cannot substitute for the runtime evidence named by the
acceptance matrix.

| Order | Work package | Scope and required gate |
| --- | --- | --- |
| WP0 | Architecture reset | Freeze ADR-002, the minimum schema/API responsibility boundary, AI/monetization/security language, CloudKit retirement, this plan, and the WP0-WP7 matrix. No code, migration, cloud resource, secret, or SDK claim. |
| WP1 | PowerSync hard-stop PoC | On macOS and iOS validate the formal Swift SDK adapter against default encrypted PowerSync SQLite and Keychain fail-closed behavior; a key/decrypt failure must not create an empty masking database. Do not use Alpha PowerSyncGRDB as a production prerequisite. Prove encrypted App Group handoff, one connect owner, read-only old-GRDB migration, no long-term two-database state, account A/B isolation, no-account local-only mode, the full backfill/queue rules, offline, missed notifications, kill/relaunch, reconnect, duplicate/retry, zero omission/duplicate, no corruption/deadlock/unrecoverable SQLITE_BUSY, zero sensitive requests, and attachment helper assessment with automatic signed-URL fallback if the helper fails. Use independent Supabase Dev us-east-1 plus PowerSync Cloud; any failure stops migration. |
| WP2 | Supabase domain | Prove the minimum eight-table domain, Auth tenant identity, RLS, private Storage, Vault boundary, Edge actions, Queues/Cron ownership, usage/quota accounting, fixed deletion verification, and forward-only legacy teardown in hosted Supabase Dev. Docker is optional for quick SQL checks, never final evidence. |
| WP3 | Auth and RevenueCat | Support Apple, Google, and Email Magic Link through Resend SMTP. Require login before purchase; bind the Supabase UUID to the RevenueCat App User ID; preserve existing App Store product IDs/capabilities; use verified signed webhooks only as wakeups, refetch canonical CustomerInfo completely, retry fetch failure without granting, and make Supabase entitlements the cloud/RLS/AI truth. Prove A/B switching and local-only behavior. |
| WP4 | Production PowerSync client | Move the PoC adapter into the real macOS/iOS apps with one main-app owner, encrypted extension handoff, SQLite-only UI/offline reads, privacy gating, attachment flow, queue settlement, quota continuation, and process/reconnect recovery. |
| WP5 | Cloud AI | Implement and prove the OpenRouter ZDR fail-closed policy, OpenRouter/Vault BYOK, one active multimodal identity at 1024 dimensions for text/image/joint/query vectors, direct image vectors with local OCR exact retrieval, independent RRF lists, sparkle-only remote search, offline lexical search, MCP before/after revalidation, and the fixed four-slice bake-off. `voyageai/voyage-multimodal-3.5` is a concrete candidate; Gemini/Qwen3-VL remain conditional until routing/1024/ZDR proof. |
| WP6 | UI, migration, deletion | Implement account-switch confirmation showing count/attachment size, account/sync/backfill/quota/cloud-stat/AI/BYOK/migration/deletion Settings, single-item and all-cloud delete, disable cloud processing, one-time CloudKit import and 90-day read-only recovery, removed Iroh, and real macOS/iOS visual/runtime acceptance. Freeze the visual matrix before implementation; require screenshots, Accessibility trees, runtime frames, visible-vs-hit geometry review, and before/after diffs. |
| WP7 | Release | Start from clean codex/integrated-delivery; run script/build_and_run.sh --verify and prove bundle/signature/source commit, stable permission identity, one process, exact artifact provenance, real iOS Simulator first, independent Dev/Alpha and Prod Supabase/PowerSync/RevenueCat environments, Sentry metrics, and staged internal -> 20 -> 100 -> 1000 rollout with stop criteria. Open Edition is source-available, not an OSI full-stack open-source claim. Revisit Cloud versus Open Edition at 100 users; Supabase Pro is required before paid launch. Deployment secrets are temporary general-secrets-store injection only. |

WP1 is an independent hard stop, not a formality. If the formal SDK,
Keychain, handoff, ownership, tenant, quota, backfill, attachment, offline,
kill, reconnect, duplicate, corruption, deadlock, SQLITE_BUSY, or privacy
evidence is missing or fails, the Coordinator stops and records the failure;
later work cannot paper over it.

WP1 execution is decomposed by the Trellis parent task
[PowerSync PoC implementation refinement](../../.trellis/tasks/08-16-powersync-poc-refinement/implement.md).
Its 17 leaf tasks are the only WP1 implementation units. Dependency-ready,
file-disjoint leaves may use at most two isolated native Codex worktree lanes;
the Coordinator still commits and integrates them serially into the single
WP1 stack layer. The WP1 row above remains the milestone boundary; it must not
be dispatched as one agent task.

## Hosted legacy boundary

The current PasteBuddy Dev hosted Supabase legacy migrations are recorded as
applied, with the historical check showing zero rows in the old domain tables.
This snapshot is not teardown authorization. Applied migrations are immutable;
WP2 may perform only a forward-only teardown after a fresh full manifest and
recount, aborting and reporting any non-zero result. Hosted Supabase Dev is the
integration-evidence authority; Docker is optional for quick SQL checks only.

## Unified success standard

The refactor is ready for release only when all applicable matrix evidence is
attached to the exact source commit and artifact:

1. Local authority and tenant safety: one PowerSync SQLite read source and one
   main-app connection; extensions use handoff only; no-account mode and
   account A/B isolation work across relaunch.
2. Privacy and security: sensitive/excluded content has zero network path;
   RLS, private Storage, Vault, and redacted Sentry diagnostics hold; cloud
   content is honestly described as service-readable, not E2EE.
3. Data lifecycle: newest 100 first, 5,000/250,000,000-byte quotas, resumable
   continuation, process/reconnect recovery, fixed deletion, and verified
   absence all work without resurrecting deleted data. Quantitative latency,
   omission, duplicate, deletion, and account-B thresholds are defined only
   in the acceptance matrix.
4. Commercial authority: login precedes purchase, RevenueCat App User ID is
   the Supabase UUID, canonical CustomerInfo is reconciled, and Supabase
   entitlements—not local flags—authorize cloud capabilities.
5. AI behavior: ZDR failure closes safely; BYOK is OpenRouter/Vault-only;
   one active multimodal identity and exact 1024 dimensions are enforced across
   text/image/joint/query vectors; direct image vectors and local OCR exact
   retrieval remain available; RRF keeps three lists independent; sparkle,
   offline lexical, MCP revalidation, and the four-slice bake-off thresholds
   pass.
6. Migration, UI, and release: CloudKit freezes before upload and stays
   read-only for 90 days; deletion/account-switch UI is observable; visual
   evidence covers the required matrix; stable macOS and iOS artifacts,
   Sentry metrics, and staged rollout gates pass.

The acceptance matrix is the only place that defines quantitative latency,
omission, duplicate, deletion, account-confirmation, and zero-network
thresholds. This plan only orders the work needed to produce that proof.

Sentry evidence is redacted and must cover sync latency, upload queue depth,
quota rejection, AI cost, Vault errors, Storage errors, and deletion task
state/failure. No payload, secret, or sensitive query is telemetry.

No document can self-mark these criteria as passed. The matrix status remains
Not run until the Coordinator records reproducible evidence.

## Execution governance

The eight stack layers are, in order:

1. codex/pb-cloud-architecture
2. codex/pb-powersync-poc
3. codex/pb-supabase-domain
4. codex/pb-revenuecat-auth
5. codex/pb-powersync-client
6. codex/pb-cloud-ai
7. codex/pb-cloud-migration-ui
8. codex/pb-cloud-release

Luna Max is the default implementation worker. The Coordinator owns Gate
review and the focused commit checkpoint. There is one writer per
responsibility boundary. One Sol agent may perform one concentrated,
independent review. The same boundary is escalated to Sol only after two
evidenced Luna failures. Parallel writers are forbidden within one worktree or
responsibility owner, but at most two dependency-ready, file-disjoint leaves
may run in isolated worktrees. Orca and hidden replacement protocols are not
part of this execution plan.

Each Trellis leaf task has one responsibility, no more than three acceptance
criteria, and an intended source/test change set of no more than five files.
One leaf equals one Luna turn, one Coordinator Gate, and one focused commit.
The next wave cannot begin until every dependency is committed and the prior
wave's combined Gate passes.

gh stack commands are non-interactive and must use explicit branch/stack
arguments. If gh stack exits 9, stop and report that the workflow is
unsupported; do not silently fall back to another branch/PR process. Each
layer must be reviewed and checkpointed before the next layer starts.

## Related authoritative documents

- [ADR-002: PowerSync and Supabase cloud convergence](ADR-002-powersync-supabase-convergence.md)
- [Supabase domain and PowerSync boundary contract](SUPABASE_SCHEMA_API_CONTRACT.md)
- [WP0-WP7 acceptance matrix](SUPABASE_ACCEPTANCE_MATRIX.md)
- [AI semantic search](../AI_SEMANTIC_SEARCH.md)
- [Monetization and RevenueCat](../MONETIZATION.md)
- [Security and privacy](../SECURITY.md)
- [CloudKit recovery](../CLOUDKIT_SYNC.md)
