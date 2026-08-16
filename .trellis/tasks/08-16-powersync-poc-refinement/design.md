# WP1 PowerSync PoC design

## Responsibility model

The parent is a planning and integration node. Leaf tasks are the only
implementation units. A leaf may produce a focused commit only after its
observable result passes. Later leaves must consume committed APIs rather than
editing an earlier responsibility opportunistically.

## Dependency graph

```text
sdk-linkage
├── db-encryption
│   ├── keychain-lifecycle
│   └── repository-boundary
│       ├── privacy-admission ───────┐
│       ├── grdb-migration ──────────┼──> backfill-checkpoint
│       └── account-isolation ─┐     │
└── connect-owner              ├──> account-confirmation ─┘
    └──────────────────┐       │
keychain-lifecycle ────┴──> appgroup-handoff

backfill-checkpoint -> quota-settlement
appgroup-handoff + quota-settlement -> attachment-decision
attachment-decision -> hosted-macos -> hosted-ios -> fault-scale -> wp1-gate
```

Dependency-ready tasks may run together only after their allowed files have
disjoint owners. A shared source checkout is never used for parallel writes.

## File ownership

| Responsibility | Exclusive owner |
| --- | --- |
| Package graph and initial PoC targets | `sdk-linkage` |
| Encrypted database opener and DB errors | `db-encryption` |
| Keychain lifecycle and key-store errors | `keychain-lifecycle` |
| Connection lifecycle and connection errors | `connect-owner` |
| App Group envelope and queue | `appgroup-handoff` |
| Schema, repository protocol, DTOs, and repository implementation | `repository-boundary` |
| Network admission decision | `privacy-admission` |
| Read-only legacy import | `grdb-migration` |
| Account identity and cache | `account-isolation` |
| Account-B consent barrier | `account-confirmation` |
| Backfill selection and checkpoint | `backfill-checkpoint` |
| Quota rejection and queue settlement | `quota-settlement` |
| Attachment transport | `attachment-decision` |
| Hosted runners and platform projects | `hosted-macos`, then `hosted-ios` |
| Fault controls and evidence | `fault-scale` |

Later leaves consume the repository, admission, connection, Keychain, and
backfill APIs frozen by these owners. They do not reopen the owner file to add
one-off behavior.

`sdk-linkage` creates the minimal hosted-mac executable shell and then hands
its `main.swift` to the later, serial `hosted-macos` owner. `hosted-ios` alone
owns the application `project.pbxproj` and PoC scheme. This handoff never spans
parallel waves.

## Stable boundaries

- Runtime database owner: one PowerSync SQLite database.
- Network admission owner: one policy decision before any PowerSync,
  Supabase, Storage, or AI-capable call.
- Connection owner: the signed main app only.
- Extension boundary: encrypted authenticated App Group handoff only.
- Migration source: old GRDB opened read-only and never written.
- Tenant identity: deterministic account-scoped cloud identity; logout removes
  only downloaded cache.
- Upload progress: durable local checkpoint; batch size 100; newest eligible
  items first.
- Quota owner: cloud rejection is final, while local history remains usable.
- Attachment owner: either the Alpha helper passes once or the design freezes
  exact-object signed URLs plus a local-only queue.
- Server language owner: Deno/TypeScript Edge Functions for V1 orchestration.
  Rust is not a service boundary. A future Rust-to-Wasm module requires
  profiling, a missed frozen Gate, an isolated benchmark, and separate user
  approval.

Executable boundary details live in
.trellis/spec/backend/powersync-poc-contracts.md. High-level architecture
remains in ADR-002; quantitative proof remains in the acceptance matrix.

## Worktree and stack rules

- Planning changes belong to codex/pb-cloud-architecture.
- The public Git Stack remains the approved eight-layer stack. All 17 WP1
  leaves integrate as focused commits into its single
  `codex/pb-powersync-poc` layer; leaf worktrees are local isolation branches,
  not 17 additional PR layers.
- The pre-existing untracked supabase directory is outside this task.
- The unfinished `/private/tmp/pastebuddy-wp1-poc` worktree and its checked-out
  `codex/pb-powersync-poc` branch are evidence only. They are not rebased,
  reset, cleaned, removed, or reused without explicit user authorization.
- After authorization, the Coordinator first archives the candidate under
  `/private/tmp`, verifies the archive, restores a clean public WP1 layer from
  the approved planning commit, and creates at most two leaf branches named
  `codex/pb-wp1-lane-<wave>-<slug>` with matching `/private/tmp` worktrees.
- Both branches in a parallel wave start at the same integrated wave-base SHA.
  Only Luna Max writes them. The Coordinator reruns each leaf Gate, creates its
  focused commit, then cherry-picks the commits into the public WP1 layer in
  canonical order and runs the combined wave Gate.
- The next wave starts only from the new integrated SHA. Dirty or failed leaf
  worktrees are preserved for evidence and are never force-cleaned.
- Orca is not part of this execution design. Native Codex subagents and Git
  worktrees provide the two implementation lanes.

## Evidence model

Every leaf records command, exit code, exact source commit, files changed,
original failure, and residual risk. Runtime leaves additionally record target
platform, bundle/process identity, account, hosted project identifiers without
secrets, and redacted network/database evidence.

## Rollback and hard stop

- Local-only leaves are reverted by their focused commit.
- Hosted PoC resources are Dev/Alpha only and must be disposable.
- A privacy leak, tenant crossover, database replacement after key failure,
  corruption, unrecoverable queue stall, or inability to meet macOS+iOS
  requirements stops WP1.
- A hard stop preserves evidence and prevents WP2 start. It does not trigger a
  custom sync-protocol fallback without a new architecture decision.
- A performance concern first produces profiling evidence. It cannot broaden a
  WP1 leaf into a Rust service or Wasm optimization.
