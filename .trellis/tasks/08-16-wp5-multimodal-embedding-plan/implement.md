# WP5 multimodal embedding contract implementation plan

## Allowed files

This planning leaf writes only:

- `.trellis/tasks/08-16-wp5-multimodal-embedding-plan/` artifacts and context
  manifests;
- `.trellis/spec/backend/index.md`;
- `.trellis/spec/backend/cloud-ai-search-contracts.md`;
- `docs/AI_SEMANTIC_SEARCH.md`;
- `docs/architecture/ADR-002-powersync-supabase-convergence.md`;
- `docs/architecture/SUPABASE_SCHEMA_API_CONTRACT.md`;
- `docs/architecture/SUPABASE_ACCEPTANCE_MATRIX.md`;
- `docs/architecture/PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md`;
- `docs/SECURITY.md`;
- `docs/IMPLEMENTATION_STATUS.md`.

No source code, package manifest, migration, Supabase resource, secret, README,
WP1 task, or Orca invocation is allowed.

## Ordered steps

1. Read the frozen WP0 documents and the current OpenRouter official embeddings,
   model, routing, and ZDR pages. Record URLs and the date of observation; do
   not treat examples as selection evidence.
2. Create the task with `task.py`, set branch
   `codex/pb-wp5-multimodal-plan`, base `codex/pb-cloud-architecture`, and scope
   `wp5-cloud-ai`; curate `implement.jsonl` and `check.jsonl` with only spec and
   research documents.
3. Write the seven-section executable code-spec. Freeze the DTO ownership,
   1024 shape/identity invariants, policy probe, candidate admission, lifecycle,
   RRF/MCP behavior, validation matrix, and falsifiable bake-off evidence.
4. Synchronize the seven permitted AI/architecture/security/status documents.
   Replace the old Qwen3 text-only default language with conditional multimodal
   candidate language, and keep every WP5 status `Not run`.
5. Run `task.py start` only after the complex planning artifacts and context
   manifests exist, then verify the active task and task metadata.

## Verification and Gate

- `python3 ./.trellis/scripts/task.py validate .trellis/tasks/08-16-wp5-multimodal-embedding-plan`
  exits 0 with both JSONL manifests containing real entries.
- `python3 ./.trellis/scripts/task.py current --json` reports this task with
  status `in_progress`, branch `codex/pb-wp5-multimodal-plan`, and base branch
  `codex/pb-cloud-architecture`.
- `git diff --check` exits 0; `git status --short` contains only the explicitly
  allowed task/spec/document files (plus no source/config/package changes).
- Search the changed docs for `WP5` and confirm status remains `Not run`; no text
  says a provider, runtime, model selection, or bake-off has passed.

## Stop conditions

- Stop and report a hard stop if official OpenRouter evidence cannot prove the
  actual route's input modalities, exact 1024 output, or both ZDR/data-collection
  fields. Do not substitute a text-only model or a generated image caption.
- Stop if any permitted document claims implementation or silently reintroduces
  direct comparison across embedding identities.
- This leaf does not run a cloud request, read a credential, build the app, run
  UI acceptance, or mark the WP5 matrix Pass.

## Handoff evidence

Report the changed-file list, official OpenRouter source URLs and conditional
model findings, task validation/current-task exit codes, `git diff --check`
output, key decisions, residual risks, and the suggested focused commit subject.
No commit or push is performed by this leaf.
