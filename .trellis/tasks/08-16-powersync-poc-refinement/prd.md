# PowerSync PoC implementation refinement

## Goal

Turn WP1 from one XL work package into independently verifiable Trellis leaf
tasks. The result must let Luna Max implementers complete bounded,
non-overlapping responsibilities in at most two isolated worktrees while the
Coordinator alone integrates them and decides Pass, Fail, or Hard Stop from
reproducible evidence.

## Background

The architecture is already frozen by
docs/architecture/ADR-002-powersync-supabase-convergence.md. The previous WP1
assignment combined dependency integration, encryption, process ownership,
repository migration, privacy, account switching, backfill, quota,
attachments, two Apple platforms, hosted services, and fault injection. That
scope made failures hard to localize and allowed unfinished experiments to
accumulate.

## Confirmed facts

- WP0 is committed and the active stack base is codex/pb-cloud-architecture.
- The production target remains one PowerSync-managed SQLite authority.
- The old GRDB database is read-only migration input.
- PowerSync Cloud and an independent Supabase Dev project are required for the
  hosted Gate; mocks and compilation alone cannot pass it.
- The unfinished candidate in /private/tmp/pastebuddy-wp1-poc is not an
  accepted baseline and cannot be committed without satisfying a leaf task.
- All implementation subagents remain stopped until this planning task is
  reviewed and the user explicitly approves implementation.

## Requirements

- R1: The parent task owns only requirements, dependency order, cross-child
  invariants, and the final integration decision. It does not own code.
- R2: Each child owns one falsifiable responsibility, touches no more than five
  intended source/test files unless its PRD is revised, and has at most three
  acceptance criteria.
- R3: A child starts only after every dependency is committed and its own
  planning artifacts are reviewed.
- R4: One Luna Max turn implements one child. The Coordinator independently
  reruns its checks and creates the focused commit.
- R5: The same responsibility may receive at most two evidenced Luna repair
  turns. A third attempt requires Sol implementation.
- R6: Sol is not used after every leaf. One independent Sol review runs only
  after all local and hosted WP1 evidence exists, unless a hard architectural
  contradiction is found earlier.
- R7: Runtime proof must be bound to source commit, app build, environment,
  account, and redacted evidence. Secrets and clipboard payloads never enter
  task artifacts.
- R8: Missing hosted credentials, unavailable SDK behavior, or a failed
  privacy/integrity test produces Hard Stop, not a mock substitute.
- R9: V1 server actions remain Deno/TypeScript Edge Functions. No leaf may add
  a standalone Rust backend or rewrite PowerSync. Rust-to-Wasm requires a new
  approved task plus profiling and benchmark evidence for a pure-compute
  bottleneck.
- R10: Parallel work is allowed only for dependency-ready leaves with disjoint
  file owners in separate worktrees. At most two Luna Max implementation lanes
  may run. The Coordinator serially reviews, commits, and integrates each leaf,
  then runs a combined wave Gate before starting another wave.

## Cross-child acceptance criteria

- [ ] All 17 children are individually Passed and integrated in the canonical
  dependency order, with no accepted child relying on the unfinished broad
  candidate.
- [ ] WP1 final evidence proves macOS+iOS local-first sync, account isolation,
  zero sensitive network requests, omission=0, duplicate=0, and no corruption,
  deadlock, or unrecoverable SQLITE_BUSY.
- [ ] The independent final review has no unresolved P0/P1 finding and the
  Coordinator records either WP1 Pass or a documented Hard Stop.

## Out of scope

- Supabase production domain schema, RevenueCat, Cloud AI, settings UI,
  CloudKit retirement, and release rollout remain WP2-WP7.
- No production Supabase, PowerSync, RevenueCat, Storage, or Vault resource is
  created or mutated in this planning task.
- This task does not redesign PowerSync, add a custom revision/cursor protocol,
  or revive the superseded WP1 SQL platform.
- This task does not introduce a Rust service, Rust webhook worker, Rust sync
  engine, or unmeasured Rust/Wasm optimization.

## Blocking open questions

None. Hosted service credentials are an execution prerequisite and may block
the relevant child, but they do not change the approved product behavior.
