# PowerSync and Supabase WP0-WP7 acceptance matrix

## Gate rules

This matrix is frozen by WP0. The [Cloud Sync and AI Refactor Plan](PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md)
is the sole authority for implementation scope and order; this file is the
authority for proof. Every implementation row starts as `Not run — WP0
documentation only`; the WP0 documentation row may be `Ready for Coordinator
Gate` without being a runtime Pass.
A document, source scan, fake transport, static preview, or compilation result
is intermediate evidence, never a Pass.

The Coordinator records the exact source commit, artifact, build, environment,
account state, privacy state, and reproducible evidence for every passed row.
Sensitive clipboard contents, raw keys, tokens, signed transactions, query
text, and App Group handoff bytes never enter evidence. Runtime proof uses the
real signed macOS/iOS applications, real user paths, relaunch, and failure or
retry states as applicable.

## Quantitative and zero-tolerance criteria

These are release-blocking proof thresholds, not WP0 implementation claims.

| Criterion | Required result and evidence | Gate |
| --- | --- | --- |
| Responsiveness | Local capture to visible UI p95 <=100 ms; online cross-device propagation p50 <=2 s and p95 <=5 s. | WP1/WP4/WP7 |
| Cloud AI latency | pgvector query p95 <=500 ms; explicit sparkle click to displayed results p95 <=3 s. | WP5 |
| Reliability | Offline, reconnect, and backfill produce omission=0 and duplicate=0; no corruption, deadlock, or unrecoverable `SQLITE_BUSY`. | WP1/WP4 |
| Backfill | 5,000-item history pauses, quits, relaunches, and resumes from the last uploaded checkpoint; quota continuation is observable. | WP1/WP4 |
| Account confirmation | After account B login and before any PowerSync connect, backfill, or cloud upload, existing history uploaded to B = 0; the confirmation shows compliant project count and attachment total bytes. | WP1/WP3/WP6 |
| Tenant isolation | A/B cross-access = 0 across database, Storage, PowerSync sync stream, semantic data, and Vault; deterministic account-scoped IDs do not merge. | WP1/WP2/WP3 |
| Sensitive network | Sensitive or excluded provider, Supabase, and PowerSync requests = 0, including extensions and AI/OCR paths. | WP1/WP5 |
| Deletion | After verified all-cloud deletion, negative queries find deletable cloud content/AI/asset/domain Postgres rows = 0; normal-login `profiles`/`entitlements` and deletion-request/status/audit metadata remain. Storage objects = 0, vectors = 0, semantic documents = 0, and Vault credential mappings/secrets = 0. Account deletion, not `all_cloud`, clears the account scope. | WP2/WP6 |
| Delivery evidence | Clean `codex/integrated-delivery` macOS artifact and real iOS Simulator run show the same account with reproducible source/build identity. | WP7 |

## Matrix

| Gate | Required falsifiable result and evidence | Owner | Status |
| --- | --- | --- | --- |
| WP0 | ADR-002, minimum domain contract, AI, monetization, security, CloudKit, README, implementation status, and this plan describe PowerSync + Supabase + RevenueCat. V1 acceptance is macOS+iOS; Android/Web reservations do not count toward WP1-WP7. Old custom sync/device-crypto behavior is historical or explicitly rejected. | Coordinator | Pass — Coordinator documentation Gate 2026-08-16; no runtime claim |
| WP1 SDK/encryption foundation | Exact PowerSync/encrypted-SQLite dependencies link on macOS and iOS; encrypted open/reopen succeeds; an existing database with a missing, corrupt, or wrong Keychain key fails closed without mutation or empty replacement. | Luna / Coordinator | Not run — must pass before ownership work |
| WP1 ownership and handoff | Exactly one main-app PowerSync connection owner exists. Keyboard/share/action extensions cannot open or connect the database and use only authenticated encrypted App Group handoff; tamper, partial write, duplicate, and crash cases fail safely with zero plaintext persistence. | Luna / Coordinator | Not run |
| WP1 repository, privacy, and migration | Local-only, synced-replica, and upload/error state use one PowerSync SQLite authority. Sensitive, excluded, signed-out, and sync-disabled fixtures produce zero network-capable calls. Legacy GRDB is read-only migration input, its digest remains unchanged, and migration resumes without duplicate logical items. | Luna / Coordinator | Not run |
| WP1 account, backfill, quota, and attachment | A/B cloud IDs, cache, checkpoints, and pending work are isolated. Before account-B consent, connect/backfill/upload are zero. Backfill is newest-first in settled batches of 100 and resumes after pause/relaunch. Quota rejection remains local and cannot block later work. The Alpha attachment helper is evaluated once, then either passes all fixed cases or is replaced by the frozen exact-object signed-URL/local-queue fallback. | Luna / Coordinator | Not run |
| WP1 hosted and fault Gate | Independent hosted Supabase Dev (us-east-1) and PowerSync Cloud prove the real macOS and iOS Simulator paths. Missed notifications, offline, reconnect, duplicate/retry, kill/relaunch, 5,000 items, and the attachment boundary end with omission=0, duplicate=0, sensitive requests=0, and no corruption, deadlock, or unrecoverable `SQLITE_BUSY`. | Luna / Coordinator | Not run — any failure stops PowerSync |
| WP1 final decision | The Coordinator binds every leaf to an exact commit/build/environment and runs one concentrated independent Sol review. No unresolved P0/P1 or missing real evidence remains. The outcome is explicitly Pass or Hard Stop; only Pass permits WP2. | Coordinator / Sol reviewer | Not run |
| WP2 domain | A disposable hosted Supabase Dev project proves Auth tenant isolation, RLS, private Storage, Vault boundary, Edge actions, Queues/Cron ownership, quota accounting, and the eight frozen domain tables. Direct table CRUD and anonymous access are denied. | Luna / Coordinator | Not run |
| WP2 legacy boundary | PasteBuddy Dev hosted legacy migrations are already applied and the historical old-domain table check is zero rows; this snapshot is not teardown authorization. Applied migrations are not modified or deleted. Before any forward-only teardown, a fresh full manifest and recount is recorded; any non-zero row aborts and is reported. Hosted Supabase Dev is final integration evidence; Docker is optional SQL smoke evidence only. | Luna / Coordinator | Not run |
| WP2 deletion | Idempotent item, semantic-index, all-cloud, account, and BYOK actions set `deleted_at` where applicable, use the fixed order semantic/vector -> Storage -> clipboard -> AI profile -> Vault for all-cloud, increment `cloud_epoch` and close cloud writes, and run a negative query per class. All deletable cloud content/AI/asset/domain rows must be empty before success; normal-login `profiles`/`entitlements` and deletion-request/status/audit metadata remain for `all_cloud`, while account deletion clears the account scope. Old-epoch AI/asset work cannot commit; status-only changes and arbitrary next phases cannot complete cleanup. | Luna / Coordinator | Not run |
| WP2 queue settlement | Permanent quota or policy rejection is settled from the PowerSync queue, becomes a visible local-only error, cannot retry forever, and does not block later items. Temporary freeze and SDK settlement behavior are proved in WP1 rather than invented here. | Luna / Coordinator | Not run |
| WP3 Auth + RevenueCat | Apple, Google, and Email Magic Link (via Resend SMTP) are exercised. User signs in before purchasing; Supabase UUID equals RevenueCat App User ID; no anonymous RevenueCat user is created; existing App Store product IDs and capability mapping remain. | Luna / Coordinator | Not run |
| WP3 reconciliation | Signed RevenueCat webhook is only a wakeup. The client/server refetches complete canonical CustomerInfo; fetch failure retries and never grants. Client CustomerInfo may refresh UI quickly, but Supabase entitlements are the cloud/RLS/AI truth. Restore, expiry, revoke, invalid session, and A/B confirmation are demonstrated after login and before any PowerSync connect or upload. | Luna / Coordinator | Not run |
| WP4 production adapter | The formal adapter is installed in the real app with one main-app connection owner, encrypted extension handoff, SQLite-only UI/offline reads, privacy gating, attachment flow, queue settlement, quota continuation, duplicate/reconnect/kill recovery, and no old-GRDB write authority. | Luna / Coordinator | Not run |
| WP4 migration | CloudKit latest Snapshot is local migration input only; writes freeze before upload, macOS/iOS markers persist, and CloudKit is read-only recovery for 90 days. Sensitive/excluded content never reaches PowerSync. | Luna / Coordinator | Not run |
| WP5 Cloud AI | Sensitive/excluded content has zero network path. OpenRouter `provider.zdr=true` and `data_collection=deny` are probed for every platform/BYOK route; unavailable ZDR fails closed. BYOK is OpenRouter-only, raw key is Vault-only, and only fingerprint/status are client-visible. | Luna / Coordinator | Not run |
| WP5 search | Qwen3 Embedding at 1024 is the default candidate; one active embedding identity per tenant; identity changes invalidate old vectors and rebuild resumably. RRF keeps server vector, server semantic FTS, and local SQLite lexical ranks independent. Sparkle is the only remote UI trigger; offline lexical remains usable. | Luna / Coordinator | Not run |
| WP5 authorization | MCP is explicit and revalidates session, entitlement, tool permission, and item visibility immediately before and after every remote await. The fixed bake-off records dataset/policy/model/provider/ZDR/latency/cost/failure evidence and requires JSON >=99.5%, leakage=0, Recall@5 >=0.85, and nDCG@5 >=0.80. | Luna / Coordinator | Not run |
| WP6 UI / migration / deletion | Settings show account, sync/backfill, quota, cloud data statistics/view, AI, BYOK, migration/deletion state, disable-cloud-processing, delete-one, and delete-all-cloud actions. After B login and before any PowerSync connect, backfill, or upload, confirmation shows compliant project count and attachment total; refusal remains local-only. Fixed deletion is verified, not merely marked succeeded. | Luna / Coordinator | Not run |
| WP6 visual matrix | Before implementation, freeze coverage for light/dark, desktop/phone/tablet, compact/regular, portrait/landscape, Dynamic Type/accessibility sizes, loading/error/empty, every applicable business state, and shown/hidden/expanded/collapsed states. Visible geometry/material/layout is reviewed separately from interaction/hit geometry. | Luna / Coordinator | Not run |
| WP6 visual evidence | Real macOS/iOS apps are operated with Computer Use. Every applicable combination retains a screenshot, Accessibility tree, target window/view frame, environment/state labels, and before/after visual diff. Unexpected movement, clipping, overlap, material, or hit geometry is a failure; static previews do not count. | Luna / Coordinator | Not run |
| WP7 release | Release starts from clean `codex/integrated-delivery`; `script/build_and_run.sh --verify` proves bundle, signature, source commit, stable bundle path, exactly one process, and stable permissions. Record `accessibilityTrusted=true`, `stableLaunchPathMatched=true`, bundle identifier/path, signing channel, and exact artifact provenance. Dev/Alpha and Prod Supabase, PowerSync, and RevenueCat configurations are independent; Supabase Pro precedes paid launch. | Coordinator / Release | Not run |
| WP7 rollout | A real iOS Simulator run precedes physical artifacts. Rollout is exactly internal -> 20 -> 100 -> 1000 users; each stage has evidence and stops on a security, tenant, sensitive-network, deletion, crash/corruption, quota, latency, redaction, or critical UX failure. At 100 real users record the Cloud Edition versus source-available Open Edition decision; do not call Open Edition OSI full-stack open source. Sentry covers sync latency, upload queue depth, quota rejection, AI cost, Vault errors, Storage errors, deletion task state/failure, with payload/secret redaction. | Coordinator / Release | Not run |

## Evidence and stop conditions

The Coordinator may mark a gate Pass only when its evidence is reproducible
against the exact build and source commit. Security, tenant isolation,
entitlement, privacy, deletion, quota, real-runtime, or quantitative failures
block the next gate. WP1 is a hard stop for the entire PowerSync migration;
WP0 cannot waive it. A failed visual gate retains its screenshot/tree/frame/diff
and requires a root-cause change before another attempt.

## Work-package ownership

The eight stack layers are codex/pb-cloud-architecture,
codex/pb-powersync-poc, codex/pb-supabase-domain,
codex/pb-revenuecat-auth, codex/pb-powersync-client, codex/pb-cloud-ai,
codex/pb-cloud-migration-ui, and codex/pb-cloud-release. Luna Max is the
default implementation worker. Coordinator owns Gate and commit checkpoint;
one Sol review is a concentrated independent review, and the same boundary
reaches Sol only after two evidenced Luna failures. There is one writer per
boundary. gh stack is non-interactive with explicit arguments; exit 9 stops the
workflow.
