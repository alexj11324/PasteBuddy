# Cloud AI search contracts

> Status: WP5 planning only. These contracts describe the implementation and
> evidence Gate; they do not prove that an Edge Function, OpenRouter route,
> provider policy, database row, or runtime path exists.

## 1. Scope / Trigger

- **Scope:** the authenticated WP5 path that admits a privacy-approved text or
  image item, creates or queries a 1024-dimensional multimodal embedding,
  stores/reads a tenant-scoped semantic derivative, and fuses vector, server
  semantic FTS, and local lexical results.
- **Trigger:** indexing is scheduled only after the local privacy decision and
  cloud capability are accepted. A user sparkle click or an explicit authorized
  MCP call starts remote search; typing, filter edits, and Enter do not.
- **Owner:** Supabase Edge owns provider policy probing, OpenRouter/Vault access,
  model identity, embedding validation, and semantic writes. PowerSync SQLite
  remains the local read/hydration authority. The client owns RRF over the three
  independent rank lists. MCP owns only its authorized call surface.
- **Non-goals:** this spec does not add screenshot capture, a second search
  index, a custom OCR engine, a custom provider, or a mandatory generative
  image-description step. WP5 remains `Not run` until the Coordinator attaches
  reproducible runtime evidence.

The official OpenRouter material used for this planning contract says that the
embeddings route accepts text and, for supported models, image or joint
text+image content. Its current model page describes
`voyageai/voyage-multimodal-3.5` as supporting text/images/video and dimensions
including 1024. The current `google/gemini-embedding-2` page describes one text
and image space but advertises recommended dimensions other than 1024; exact
1024 output therefore remains a runtime candidate check. A Qwen3-VL-Embedding
candidate is not admitted by a side-conversation example: the live OpenRouter
route, exact slug, modalities, shape, and policy must be proven.

Sources:

The official-page observation in this planning leaf was made on 2026-08-16;
model availability and provider policy remain runtime facts and must be probed
again before activation.

- [OpenRouter embeddings API](https://openrouter.ai/docs/api/reference/embeddings)
- [Create embedding request](https://openrouter.ai/docs/api/api-reference/embeddings/create-embeddings)
- [List embedding models](https://openrouter.ai/docs/api/api-reference/embeddings/list-embeddings-models)
- [Voyage multimodal 3.5](https://openrouter.ai/voyageai/voyage-multimodal-3.5)
- [Gemini Embedding 2](https://openrouter.ai/google/gemini-embedding-2)
- [Provider routing](https://openrouter.ai/docs/guides/routing/provider-selection)
- [OpenRouter ZDR](https://openrouter.ai/docs/guides/features/zdr)

## 2. Signatures (command/API/DB)

The following are the logical signatures that WP5 implementation must make
wire- and test-visible. Supabase Edge is the external API owner; no client may
choose a tenant, Vault reference, provider host, or embedding identity.

### 2.1 Identity and policy DTOs

```text
EmbeddingIdentity {
  id: string                         // opaque, immutable identity key
  model_slug: string                 // exact OpenRouter model slug
  dimensions: 1024                   // literal contract value
  routed_provider: string             // actual provider endpoint for this identity
  provider_policy_version: string    // policy evidence version/timestamp
  provider_zdr: true                 // literal contract value
  data_collection: "deny"            // literal contract value
}

EmbeddingPolicyEvidence {
  model_slug: string
  routed_provider: string
  provider_zdr: boolean
  data_collection: "allow" | "deny" | "unknown"
  observed_at: RFC3339
  source: string                      // OpenRouter endpoint/metadata reference
  policy_version: string
}
```

The server derives `EmbeddingIdentity` only after a current policy probe. A
provider fallback or policy-version change is a new identity and makes old
vectors stale; a database cast cannot make identities comparable.

### 2.2 Embedding API

```text
POST /functions/v1/cloud-ai/embedding

EmbeddingRequest {
  operation: "index" | "query"
  item_id: string | null               // required for index; null for query
  input: {
    kind: "text" | "image" | "joint"
    redacted_text: string | null       // query or approved derivative only
    private_asset_id: string | null    // server-owned private Storage asset
  }
  active_identity_id: string           // server-checked, not client-created
  privacy_decision_id: string          // server revalidates before provider call
  request_id: string                   // idempotency key within tenant/action
}

EmbeddingResponse {
  status: "accepted" | "indexed" | "ready" | "stale" | "failed"
  item_id: string | null
  identity_id: string
  dimensions: 1024
  index_state: "queued" | "ready" | "stale" | "failed"
  vector: never returned to the client
  error_code: string | null
}
```

The Edge-to-provider adapter uses the OpenRouter embeddings request with the
active model slug, `dimensions=1024`, and provider preferences
`{ "zdr": true, "data_collection": "deny" }`. It may send text, image, or
text+image content only when the model metadata and probe admit that modality.
The vector is server-internal and is committed only after shape, finiteness,
identity, and policy validation.

### 2.3 Search and rebuild APIs

```text
POST /functions/v1/cloud-ai/search

SearchRequest {
  surface: "sparkle" | "mcp"
  query_text: string                   // privacy-approved explicit query
  active_identity_id: string
  filters: { content_types: [string], pinboard_ids: [string] }
  limit: integer                       // bounded by implementation contract
  request_id: string
}

RemoteSearchResponse {
  identity_id: string
  vector_ranked: [{ item_id: string, rank: integer, score: number }]
  semantic_fts_ranked: [{ item_id: string, rank: integer, score: number }]
  stale_count: integer
  index_state: "ready" | "partial" | "failed"
}

ClientSearchResult = composeSearchResult(
  remote: RemoteSearchResponse | null,
  local_lexical_ranked: [{ item_id: string, rank: integer, score: number }],
  visibility_and_product_filters: LocalSearchFilters,
  sqlite: PowerSyncSQLite
) -> {
  filtered_vector_ranked: [{ item_id: string, rank: integer, score: number }]
  filtered_semantic_fts_ranked: [{ item_id: string, rank: integer, score: number }]
  filtered_local_lexical_ranked: [{ item_id: string, rank: integer, score: number }]
  rrf_ranked_ids: [string]
  display_state: "ready" | "partial" | "offline" | "failed" | "no_relevant_result"
  hydrated_items: [LocalClipboardItem]
}

POST /functions/v1/cloud-ai/rebuild

RebuildRequest {
  requested_identity_id: string
  cursor: string | null
  batch_size: integer
  request_id: string
}

RebuildResponse {
  identity_id: string
  next_cursor: string | null
  processed: integer
  ready: integer
  failed: integer
  complete: boolean
}
```

The Edge `RemoteSearchResponse` contains only the two independent server lists,
server identity/stale metadata, and server index status. It never returns a
local lexical list, a client RRF result, or `offline` (which is a client display
state). The client reads `local_lexical_ranked` from PowerSync SQLite, applies
current local visibility/product filters independently to all three lists before
RRF, then hydrates IDs from SQLite. Hidden or deleted items must not contribute
to ranking. Sparkle and MCP use this same remote-index and client-composition
contract; MCP receives only the authorized hydrated result shape and never raw
vectors, private asset bytes, Vault references, or hidden item payloads.

The Edge-to-provider adapter wire request is distinct from policy evidence:

```text
OpenRouterEmbeddingWireRequest {
  model: string
  input: text | image_url | joint_text_image
  dimensions: 1024
  provider: { zdr: true, data_collection: "deny" }
}
```

Those provider preferences are allowed request constraints in the official
OpenRouter schema; they are not proof that a routed endpoint complied. The
actual routed provider and current policy evidence must still be recorded and
verified. A fallback/provider-policy change creates a new identity or fails
closed.

### 2.4 Database responsibilities

- `ai_profiles.active_embedding_identity`, `embedding_model`, and
  `embedding_dimensions=1024` are the tenant's server-owned active choice.
- `semantic_documents.embedding` is `halfvec(1024)`, and its
  `embedding_identity` is mandatory for every non-deleted row.
- `index_state` is one of `queued`, `ready`, `stale`, or `failed`; a stale row is
  ineligible for vector comparison but remains inspectable for rebuild status.
- `redacted_document` and `semantic_fts` contain only approved service-visible
  derivatives. Source clipboard payloads, sensitive originals, raw keys, and
  provider response bodies do not enter these tables.

## 3. Contracts (request/response/env)

### 3.1 Shared-space invariant

Text projects, image projects, joint image/text projects, and text queries MUST
use the same active `EmbeddingIdentity.id`, exact `model_slug`, exact routed
provider, policy version, and `dimensions=1024`. A model, route, tokenizer,
policy identity, or dimension change performs this transaction at the server
boundary:

1. advance the tenant's active identity;
2. mark every old semantic vector `stale` before new identity rows become
   searchable;
3. rebuild in resumable, idempotent batches; and
4. expose only rows whose identity equals the current identity.

An image can produce a direct image vector or a joint image/text vector. A
generated GPT/VLM summary is optional and may be added only as a separately
measured enhancement; it is not a prerequisite for an image vector.

### 3.2 Privacy, authorization, and secret boundary

- The local privacy decision runs before App Group handoff, private asset upload,
  OCR-derived work, embedding, and search. Sensitive/excluded/ambiguous input
  has zero network path and no retry.
- Supabase Auth/RLS supplies tenant identity. The client cannot override the
  authenticated user, active identity, private asset path, or Vault reference.
- Platform and BYOK calls both require a current policy probe proving
  `provider_zdr=true` and `data_collection="deny"` for the actual route. BYOK
  selects only the existing server-side Vault credential mapping. No raw key,
  opaque Vault reference, provider token, or request body is returned or logged.
- The Edge path may emit bounded status, rank IDs, latency, cost, and failure
  codes to diagnostics. It must not emit clipboard contents, sensitive query
  text, vectors, asset bytes, keys, or policy secrets.

### 3.3 Candidate admission and OpenRouter behavior

The bake-off may include a candidate only after all of these are observed for
the same exact route:

1. OpenRouter exposes the exact model slug through its embedding model/endpoint
   metadata.
2. The model accepts text and image inputs and the required image or joint form.
3. A text fixture, image fixture, and joint fixture each return exactly 1024
   finite values.
4. The actual routed provider is recorded and its policy evidence proves
   `provider.zdr=true` and `data_collection="deny"`.
5. Each of the four slices independently passes the frozen quality/error/
   leakage Gate: Recall@5 >= 0.85, nDCG@5 >= 0.80, and sensitive leakage = 0.
   Per-slice latency and qualified-request cost are recorded. Overall averages
   are reported but cannot rescue a failing slice.

The current concrete candidate is `voyageai/voyage-multimodal-3.5`, because the
official OpenRouter page states text/image/video input and lists 1024. Gemini
Embedding 2 and Qwen3-VL-Embedding remain conditional; a model page or chat
example alone is insufficient. The lowest-cost candidate among passing
candidates may become active; otherwise WP5 hard-stops with no remote index.

### 3.4 Retrieval and MCP contract

- `vector_ranked` uses only current-identity vectors.
- `semantic_fts_ranked` uses server semantic FTS and is never folded into the
  local list.
- The client obtains `local_lexical_ranked` from the existing PowerSync SQLite
  lexical/OCR path. It remains available offline; `offline` is a client display
  state, not an Edge response state.
- `composeSearchResult` applies current local visibility and product filters to
  each independent list before RRF, then hydrates the fused IDs from SQLite.
  Hidden/deleted items cannot influence ranking, and a remote response cannot
  become a second UI cache.
- Sparkle is an explicit remote action. MCP is a separate explicit tool call
  that revalidates session, entitlement, MCP permission, and item visibility
  immediately before and after every remote `await`; a changed check returns no
  payload.

### 3.5 Environment and evidence keys

The implementation may read only server-managed references for the existing
OpenRouter platform credential and BYOK Vault mapping. It MUST NOT add keys to
the repository, client bundle, `.env`, task artifacts, logs, or tests. The
evidence report emits one row per candidate and required slice; each row
contains only:

```text
candidate_slug, routed_provider, model_version, identity_id,
dimensions, provider_policy_version, provider_zdr, data_collection,
dataset_version, privacy_policy_version, slice, latency_ms,
qualified_request_cost,
leakage_count, recall_at_5, ndcg_at_5, failure_counts,
enhancement_applicable, json_validity_rate, enhancement_retrieval_delta
```

`enhancement_applicable=false` is required for a pure multimodal embedding
candidate; such a candidate does not output JSON and has
`json_validity_rate=null`, so JSON validity is not a base admission gate. If an
optional GPT/VLM structured semantic-document enhancement is evaluated, that
optional enhancement's `enhancement_applicable=true` makes JSON validity >=
99.5% and a positive retrieval delta mandatory in addition to the same
privacy/ZDR and four-slice gates. The field is conditional, never an
unconditional candidate threshold.

No clipboard payload, token, key, sensitive query, private asset, or signed
transaction is evidence.

## 4. Validation & Error Matrix

| Condition | Required result | Error/status | Network/write behavior |
| --- | --- | --- | --- |
| Privacy decision denies or is unknown | Reject before any remote operation | `privacy_denied` / `failed` | Zero provider, Storage, Supabase, and Sentry payload path; no retry |
| Auth, entitlement, MCP permission, or item visibility is invalid | Reject before request and after every await | `authorization_changed` / `failed` | No result payload; no semantic write |
| Candidate lacks text, image, or joint input support | Exclude candidate | `unsupported_modality` / `failed` | No index activation; lexical search remains available |
| Policy probe missing, stale, conflicting, or not for actual route | Fail closed | `provider_policy_unverified` / `failed` | No provider request and no vector write |
| Request uses a custom host or client-supplied raw key | Reject | `provider_route_forbidden` / `failed` | No request; BYOK remains Vault-only |
| Provider returns a non-1024 or non-finite vector | Reject response | `embedding_shape_invalid` / `failed` | No semantic row; preserve source item |
| Response model/route/identity differs from active tuple | Reject response | `embedding_identity_mismatch` / `stale` | No comparison or commit; schedule matching rebuild |
| OpenRouter 429/5xx/timeout | Bounded server retry only when privacy/auth still valid | `provider_unavailable` / `queued` or `failed` | No partial vector write; terminal failure is visible |
| Identity changed while work is in flight | Invalidate old work | `stale_identity` / `stale` | Late result cannot commit; rebuild uses new cursor |
| Delete request or `deleted_at` wins while work is in flight | Suppress late commit | `item_deleted` / `failed` | No resurrection of semantic/vector row |
| Optional GPT/VLM enhancement fails | Keep base direct/joint vector | `enhancement_unavailable` / `ready` | No indexing failure and no mandatory retry |
| A pure embedding candidate has no optional structured enhancement | Accept base evidence without JSON metric | `enhancement_applicable=false` / `ready` | `json_validity_rate=null`; base four-slice gates still required |
| Optional GPT/VLM structured enhancement is enabled but JSON validity <99.5% or retrieval delta is not positive | Reject enhancement, or hard stop if it is required by the chosen design | `enhancement_quality_invalid` / `failed` | Base direct/joint vector may remain; no enhancement claim |
| No candidate passes the four independent slice gates | Hard stop WP5 | `bakeoff_hard_stop` / `failed` | No active cloud AI index or provider claim |

## 5. Good / Base / Bad Cases

### Good

- A privacy-approved screenshot is embedded directly by an OpenRouter-routed
  candidate that returns 1024 finite values. Its OCR remains a local exact
  signal; the semantic row records the current identity, and a text query uses
  the same identity to retrieve it through `vector_ranked`.
- A candidate's provider probe records `zdr=true` and `data_collection=deny`,
  each of the four report slices independently meets Recall@5 >= 0.85,
  nDCG@5 >= 0.80, and leakage=0, and a rebuild after model activation resumes
  from a durable cursor without comparing old vectors. Per-slice latency and
  qualified-request cost are retained; an overall average is informational.
- Sparkle and MCP produce the same current-index IDs while MCP revalidation
  suppresses a result when entitlement changes during the remote await.

### Base

- An image has no approved semantic derivative or the candidate cannot accept
  images. The item remains local; OCR/local lexical retrieval works, while
  remote vector search reports `partial` rather than a false empty history.
- A policy probe or provider request is temporarily unavailable. The item stays
  queued/failed visibly, no unvalidated vector is stored, and offline lexical
  search remains usable.

### Bad

- Qwen3 text-only vectors are compared with image vectors made from a generated
  caption. This creates two semantic spaces and violates the shared identity.
- A provider returns 1536 values, the adapter truncates them to 1024, and the
  row is marked ready. Shape coercion is not validation and must fail closed.
- The report averages text→text and image slices so that screenshot OCR exact
  retrieval or leakage failures disappear. Every required slice must meet its
  own thresholds; averages cannot rescue a failure.
- A pure embedding candidate is rejected because it lacks JSON output, or a
  JSON-validity threshold is applied without enabling an optional structured
  GPT/VLM enhancement. JSON validity is conditional, not a base model gate.
- MCP calls a separate model or index, returns a cached item after visibility
  changed, or treats a tool permission as provider authorization.

## 6. Tests Required (with assertion points)

All ad-hoc probes and smoke fixtures belong in a temporary directory; no test
file is persisted by this planning leaf. Future formal pipeline tests must
retain redacted evidence only.

1. **DTO/shape contract:** text, image, and joint fixtures assert a finite vector
   of length 1024; any other length, NaN, infinity, model, route, or identity
   returns `embedding_shape_invalid` or `embedding_identity_mismatch` and writes
   no semantic row.
2. **Policy contract:** provider fixtures assert that `zdr=true` and
   `data_collection=deny` are required for platform and BYOK; missing/stale or
   mismatched evidence returns `provider_policy_unverified` before network
   admission. A custom host/raw client key is rejected.
3. **Candidate bake-off:** the report schema requires each of the four slices to
   independently meet Recall@5 >= 0.85, nDCG@5 >= 0.80, and leakage count = 0;
   per-slice latency, qualified-request cost, and failure counts are recorded.
   A pure embedding candidate records `enhancement_applicable=false` and
   `json_validity_rate=null`. If an optional GPT/VLM structured enhancement is
   enabled, assert JSON validity >=99.5% and a positive retrieval delta in
   addition to the base gates. An unproven 1024/ZDR field or any failing slice
   cannot become active.
4. **Shared-space lifecycle:** one identity is used for text→text,
   text→image, image→image, and joint retrieval. Changing identity marks all
   prior rows stale, excludes them from query results, and resumes a duplicate-
   free rebuild after pause/relaunch.
5. **RRF independence:** Edge returns only vector and semantic FTS lists;
   PowerSync SQLite supplies local lexical results. The client filters all three
   lists for current visibility/product rules before RRF, so hidden/deleted IDs
   cannot affect rank. Changing one list changes only its RRF contribution.
   Offline mode is a client display state and still returns local lexical
   results.
6. **Privacy and deletion:** sensitive/excluded fixtures create zero network
   calls; `deleted_at` or a newer identity prevents late vector commits and
   cannot resurrect an item.
7. **MCP await revalidation:** change session, entitlement, MCP permission, or
   visibility before/after a remote await and assert no result payload is
   returned. Sparkle remains the only built-in remote UI trigger.
8. **Runtime Gate (later, not this leaf):** real signed macOS/iOS apps exercise
   indexing, search, offline/partial/error states, and the evidence matrix.
   Static scans, compilation, or a fake transport cannot mark WP5 Pass.

## 7. Wrong vs Correct

### Wrong

```text
text item -> Qwen3 text embedding (1024)
image item -> GPT/VLM caption -> Qwen3 text embedding
query -> Qwen3 text embedding
provider -> accept the first route; infer ZDR from documentation
search -> merge vector and FTS into one list; let MCP use a second index
```

This is wrong because image retrieval depends on a generated description,
provider policy is not verified for the actual route, and the index can compare
incompatible semantics or hide exact-text failures.

### Correct

```text
privacy gate -> current OpenRouter multimodal candidate + actual ZDR probe
text/image/joint/query -> same active identity, same model, exactly 1024 values
image OCR -> local exact signal; direct/joint vector is the semantic signal
vector list + server semantic FTS list + local lexical list -> independent RRF
MCP -> same index, permission/visibility revalidated before and after await
model/route/policy change -> stale all old vectors -> resumable rebuild
```

The correct path fails closed when any modality, shape, identity, privacy, or
policy invariant is unproven, and it remains a plan until the Coordinator records
the required runtime Gate.
