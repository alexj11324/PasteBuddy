# WP1 PowerSync PoC execution plan

## Global execution rule

Do not start implementation until the user approves this plan and separately
authorizes preservation plus cleanup of the unfinished WP1 candidate. Use
native Codex subagents only; do not use Orca.

Run no more than two Luna Max implementers, each in an isolated leaf worktree
created from the same wave-base SHA. For every leaf: the implementer reads its
PRD, implementation plan, and PowerSync PoC code-spec; changes only its
allowlist; runs its checks; and hands the diff back without committing. The
Coordinator reruns the checks, inspects the exact diff, creates the focused
commit, integrates it into `codex/pb-powersync-poc`, and runs a combined wave
Gate. A failed leaf blocks its dependents and the next wave.

## Canonical integration order and parallel waves

| Wave | Canonical integration order | Dependencies | Primary output |
| --- | --- | --- | --- |
| 0 | `sdk-linkage` | WP0 | Pinned SDK and macOS/iOS compile smoke |
| 1 | `db-encryption`, then `connect-owner` | Wave 0 | Encrypted open/failure and one connection owner |
| 2 | `keychain-lifecycle`, then `repository-boundary` | `db-encryption` | Stable key lifecycle and frozen repository seam |
| 3A | `appgroup-handoff`, then `privacy-admission` | keychain + connection; repository | Encrypted handoff and zero-network admission |
| 3B | `grdb-migration`, then `account-isolation` | repository | Read-only import and tenant isolation |
| 4 | `account-confirmation` | privacy + account isolation | Pre-connect confirmation barrier |
| 5 | `backfill-checkpoint` | migration + confirmation | Newest-first durable 100-item batches |
| 6 | `quota-settlement` | backfill | Quota pause/resume and permanent settlement |
| 7 | `attachment-decision` | handoff + quota | Helper Pass or frozen signed-URL fallback |
| 8 | `hosted-macos` | attachment | Real hosted macOS path |
| 9 | `hosted-ios` | hosted macOS | Real hosted iOS Simulator path |
| 10 | `fault-scale` | hosted macOS + iOS | Fault injection and 5,000-item evidence |
| 11 | `wp1-gate` | all prior leaves | Exact evidence bundle and independent review |

Waves 1, 2, 3A, and 3B each have two disjoint implementation lanes. Logical
Wave 3 consists of two sequential batches: 3A must be integrated and pass its
combined Gate before 3B starts. Commits inside each batch are integrated
left-to-right. All other waves are single-lane. No later wave starts from an
unintegrated leaf branch.

## Worktree lifecycle

1. Commit and approve the WP0/Trellis planning checkpoint, excluding
   `supabase/`.
2. Preserve the dirty `/private/tmp/pastebuddy-wp1-poc` candidate. Archive and
   clean it only after explicit user authorization; verify the archive before
   any destructive operation.
3. Rebase the public `codex/pb-powersync-poc` stack layer onto the approved
   planning commit.
4. For each wave create one or two local leaf branches named
   `codex/pb-wp1-lane-<wave>-<slug>` and matching `/private/tmp` worktrees from
   the exact integrated wave-base SHA.
5. After Coordinator commits and integrates every leaf, run the combined wave
   Gate and record the new base SHA in the task evidence.
6. Remove only clean, fully integrated leaf worktrees. Preserve dirty or failed
   worktrees; never use `reset --hard`, `clean`, or forced removal implicitly.
7. Public PR submission remains the one WP1 stack layer. Leaf isolation branches
   are not submitted as standalone PRs.

The command shape is fixed, but these commands are not run during planning:

```bash
PB_ROOT=/Users/alexjiang/Desktop/vibe/PasteBuddy
PB_WAVE_BASE=<exact-integrated-sha>
PB_LEAF_BRANCH=codex/pb-wp1-lane-<wave>-<slug>
PB_LEAF_WT=/private/tmp/pb-wp1-<wave>-<slug>

git -C "$PB_ROOT" branch "$PB_LEAF_BRANCH" "$PB_WAVE_BASE"
git -C "$PB_ROOT" worktree add "$PB_LEAF_WT" "$PB_LEAF_BRANCH"
```

After the Coordinator verifies and commits a leaf, integration is explicit:

```bash
git -C <clean-public-wp1-worktree> cherry-pick <verified-leaf-commit>
git -C <clean-public-wp1-worktree> diff --check <wave-base>..HEAD
```

If either leaf fails, preserve its worktree, do not integrate it, and do not
start the next wave.

## Reproducible combined wave Gates

Every Gate writes a redacted manifest under
`/private/tmp/pastebuddy-wp1-evidence/<integrated-sha>/<wave>/manifest.json`.
The manifest records leaf commit(s), integrated SHA, commands and exit codes,
assertion counters, artifact paths, original failures, and residual risk. It
contains no endpoint token, secret, or clipboard payload.

| Wave | Integrated commands and required assertions |
| --- | --- |
| 0 | `swift package resolve`; `swift build --target PasteBuddyPowerSyncPoC`; `swift test --filter PowerSyncSDKSmokeTests`; `xcodebuild -scheme PasteBuddyPowerSyncPoC -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. One resolved version per dependency and no duplicate SQLite/GRDB symbol. |
| 1 | `swift test --filter EncryptedPowerSyncDatabaseTests`; `swift test --filter PowerSyncConnectionOwnerTests`; `swift build --target PasteBuddyPowerSyncPoC`. Existing-DB failure mutation count = 0 and concurrent live connector owners = 1. |
| 2 | `swift test --filter PowerSyncDatabaseKeyStoreTests`; `swift test --filter PowerSyncClipboardRepositoryTests`; `swift build --target PasteBuddyPowerSyncPoC`. Implicit key regeneration = 0, masking database creation = 0, second writable authority = 0. |
| 3A | `swift test --filter EncryptedAppGroupHandoffTests`; `swift test --filter CloudSyncAdmissionPolicyTests`; `swift build --target PasteBuddyPowerSyncPoC`. Plaintext storage matches = 0 and rejected-fixture PowerSync/Supabase/Storage/AI calls = 0. |
| 3B | `swift test --filter LegacyGRDBImporterTests`; `swift test --filter AccountIsolationTests`; `swift build --target PasteBuddyPowerSyncPoC`. Source digest/mtime changes = 0, duplicate logical imports = 0, foreign-account rows/pending work = 0. |
| 4 | `swift test --filter AccountBackfillConsentGateTests`. Pre-consent connect, synced inserts, uploads, and recorder calls = 0; displayed count/bytes equals the consumed snapshot. |
| 5 | `swift test --filter BackfillCoordinatorTests`. At least 201 items settle as `100,100,1`; omission = 0, duplicate = 0, and pause/kill/relaunch resumes from the last durable checkpoint. |
| 6 | `swift test --filter QuotaAndSettlementTests`. Both quota crossings stop new cloud work without losing local content; permanent retries = 0; later valid work proceeds. |
| 7 | `swift test --filter AttachmentTransportTests`; verify the task decision artifact exists. Exactly one transport is frozen, required-case gaps = 0, and orphan objects after cancel/delete/retry = 0. |
| 8 | `swift test --filter HostedMacIntegrationTests`; `swift run PasteBuddyPowerSyncHostedMacPoC --hosted-macos-gate`. Hosted macOS offline/upload/download/relaunch path has omission = 0, duplicate = 0, sensitive requests = 0, and evidence is bound to source/process/account/Dev project. |
| 9 | `xcodebuild -project PasteBuddyiOS.xcodeproj -scheme PasteBuddyPowerSyncPoC -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO build`; `swift test --filter HostedIOSContractTests`. macOS/iOS convergence omission = 0, duplicate = 0, and relaunch/account isolation pass. |
| 10 | `swift test --filter PowerSyncFaultInjectionTests`; `swift test --filter PowerSyncScaleTests`; verify the fault results artifact. All deterministic fault cases finish with omission = 0, duplicate = 0, corruption/deadlock/unrecoverable `SQLITE_BUSY` = 0, and sensitive requests = 0 at 5,000 items and the attachment boundary. |
| 11 | Revalidate all 18 Trellis tasks, run all prior commands against the final integrated SHA, verify every manifest and focused commit, then run one independent Sol review. Missing evidence or any unresolved P0/P1 produces Hard Stop, not Pass. |

Any command failure, missing manifest, nonzero forbidden counter, source-SHA
mismatch, or unowned diff blocks the next wave and preserves its worktrees.

## Checkpoints

- Foundation checkpoint after Wave 2.
- Ownership/privacy/migration checkpoint after Wave 4.
- Queue/attachment checkpoint after Wave 7.
- Hosted integration checkpoint after Wave 10.
- Final WP1 decision after Wave 11.

## Review and escalation

- Coordinator review happens after every child.
- Sol review happens once in child 17.
- A Luna implementation approach that fails twice on the same responsibility is
  stopped. The Coordinator records both failures and assigns a Sol
  implementation task; no third Luna micro-adjustment is allowed.
- Any material change to product scope, privacy boundary, hosted service, or
  acceptance behavior returns the affected task to planning and requires a new
  user approval.

## Planning completion checks

- Run task.py validate for the parent and all children.
- Confirm no task contains TBD or placeholder text.
- Confirm every child has no more than three acceptance criteria.
- Confirm the authoritative architecture plan links this Trellis parent task.
- Confirm git diff --check and inspect git status without staging supabase.
