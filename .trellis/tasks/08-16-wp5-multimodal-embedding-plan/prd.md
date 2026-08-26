# WP5 multimodal embedding contract

## Goal

Freeze a documentation-only, executable contract for PasteBuddy Cloud AI search:
one active OpenRouter-routed multimodal embedding identity per tenant, one
1024-dimensional shared space for text items, image items, and text queries, and
a fail-closed provider/privacy gate. WP5 remains `Not run`; this task does not
claim an implementation, hosted resource, provider approval, or runtime result.

## Dependencies

- `codex/pb-cloud-architecture` and its WP0 documents are the architectural
  base. WP1-WP4 hard-stop/runtime gates must pass before WP5 implementation.
- The existing local privacy decision, PowerSync SQLite authority, Supabase RLS,
  private Storage, and existing local OCR boundaries remain authoritative.

## Requirements

- The active identity is a tuple of model slug, provider route/policy version,
  and `dimensions=1024`. Text projects, image projects, and text queries MUST
  use that exact identity; vectors from different identities MUST never be
  compared. Any identity change marks every old vector stale and schedules a
  resumable rebuild.
- An eligible model MUST support text input, image input, and a shared text/image
  space through OpenRouter's embeddings route, and MUST return exactly 1024
  finite values for every accepted request. Images may receive a direct image or
  joint image/text vector. Local OCR, server semantic FTS, and local lexical
  search remain separate exact-text/code/identifier paths.
- Every platform or BYOK request MUST prove `provider.zdr=true` and
  `data_collection=deny` for the actual route. Missing, stale, conflicting, or
  unverifiable policy evidence fails closed. BYOK only selects the user's
  OpenRouter credential; it does not select a custom host or bypass policy.
  The Edge-to-OpenRouter adapter wire request explicitly sends
  `provider: { zdr: true, data_collection: "deny" }` and `dimensions: 1024`;
  those request constraints are not themselves proof of routed-provider
  compliance. A fallback/provider-policy change creates a new identity or
  fails closed.
- The bake-off MUST treat `voyageai/voyage-multimodal-3.5` as a concrete
  candidate because the current OpenRouter page describes text/image/video
  embeddings and lists 1024 as a supported dimension. `google/gemini-embedding-2`
  and any Qwen3-VL-Embedding slug remain conditional candidates: OpenRouter
  routing, exact 1024 output, cross-modal behavior, and ZDR evidence must be
  proven at run time before inclusion. No side-conversation example is a model
  selection.
- GPT/VLM generation is not a mandatory per-image indexing step. It may be an
  optional summary/structured-extraction enhancement only after a retrieval
  bake-off shows a measured gain and the same privacy gate passes.
- The Edge response contains only independent server vector and semantic-FTS
  lists plus identity/stale/index status. The client obtains local lexical
  results from PowerSync SQLite, applies current local visibility/product
  filters to all three lists before RRF, and hydrates fused IDs from SQLite.
  Hidden/deleted items cannot affect ranking; `offline` is a client display
  state, not an Edge response state. MCP and sparkle use this same index and
  client fusion contract; MCP is an authorized call surface, not a provider,
  and every remote await is revalidated before and after it.

## Acceptance Criteria

- [ ] AC1 — Candidate eligibility is falsifiable: for every candidate, the
  evidence bundle records the exact OpenRouter model slug, supported text/image
  inputs, a successful 1024-value response for text, image, and text+image
  fixtures, actual routed provider, `provider.zdr=true`, and
  `data_collection=deny`; a missing field or failed probe leaves the candidate
  unselected and the request fail-closed.
- [ ] AC2 — Shared-space and lifecycle semantics are falsifiable: fixtures prove
  text→text, text→image, image→image, and joint image/text retrieval use one
  active identity and 1024-dimensional vectors; changing identity marks all old
  rows stale, never compares them to new vectors, and resumes rebuild after a
  pause/relaunch without duplicate or missing rows.
- [ ] AC3 — The bake-off is falsifiable: a redacted report contains the four
  required slices (text→text, text→image, image→image, screenshot OCR exact
  retrieval), and every slice independently meets Recall@5 >= 0.85,
  nDCG@5 >= 0.80, and sensitive leakage = 0. Latency, cost per qualified
  request, failures, and overall averages are recorded per slice/candidate;
  averages cannot rescue a failing slice. Pure embedding candidates set
  `enhancement_applicable=false` and `json_validity_rate=null`; only an enabled
  optional GPT/VLM structured enhancement requires JSON validity >=99.5% and a
  positive retrieval delta, in addition to the same privacy/ZDR gates. WP5
  remains `Not run` until Coordinator runtime evidence meets these thresholds.

## Out of scope

- No Swift/TypeScript implementation, migration, Edge Function, Supabase
  resource, PowerSync configuration, provider key, or deployment.
- No provider is selected by documentation alone. Qwen3 text-only embedding is
  not a valid multimodal default; Gemini/Qwen3-VL remain conditional.
- No screenshot capture feature, custom OCR engine, second index, separate MCP
  provider, or per-image mandatory generative description path.

## Sources and status

- OpenRouter official embeddings documentation:
  https://openrouter.ai/docs/api/reference/embeddings
- OpenRouter official model pages:
  https://openrouter.ai/voyageai/voyage-multimodal-3.5 and
  https://openrouter.ai/google/gemini-embedding-2
- OpenRouter official provider routing/ZDR documentation:
  https://openrouter.ai/docs/guides/routing/provider-selection and
  https://openrouter.ai/docs/guides/features/zdr
- Current implementation status remains WP5 `Not run`.
