# WP5 multimodal embedding contract design

## Boundary and ownership

This is a planning artifact for the `codex/pb-cloud-architecture` layer. The
future implementation has the following single owners:

| Concern | Owner | Contract boundary |
| --- | --- | --- |
| Privacy admission | Existing local privacy decision | Reject sensitive/excluded items before handoff, upload, OCR-derived AI work, or search. |
| Provider policy and embedding call | Supabase Edge action through OpenRouter | Probe the actual route, request `zdr=true` and `data_collection=deny`, and return only a validated vector or an explicit failure. |
| Semantic document and identity | Supabase `semantic_documents` / `ai_profiles` | Store a redacted derivative, `halfvec(1024)`, and the active identity; never store raw sensitive content or a client-visible Vault reference. |
| Local authority and exact matching | PowerSync-managed SQLite plus existing OCR/FTS paths | Hydrate visible IDs, preserve local lexical/OCR exact retrieval, and never become a second remote-result cache. |
| Rank fusion | Client search coordinator | Keep vector, server semantic FTS, and local lexical lists independent, then apply RRF. |
| Authorized MCP surface | Existing MCP service | Reuse the same index and revalidate session, entitlement, tool permission, and item visibility before and after every remote await. |

The Edge search response is deliberately narrower than the client result:

```text
RemoteSearchResponse {
  identity_id: string
  vector_ranked: [{ item_id, rank, score }]
  semantic_fts_ranked: [{ item_id, rank, score }]
  stale_count: integer
  index_state: "ready" | "partial" | "failed"
}

ClientSearchResult = composeSearchResult(
  remote: RemoteSearchResponse | null,
  local_lexical_ranked: [{ item_id, rank, score }],
  current_local_filters: LocalSearchFilters,
  sqlite: PowerSyncSQLite
) -> {
  rrf_ranked_ids: [string]
  display_state: "ready" | "partial" | "offline" | "failed" | "no_relevant_result"
  hydrated_items: [LocalClipboardItem]
}
```

The Edge response MUST NOT contain a local lexical list or final RRF IDs.
`composeSearchResult` applies current local visibility/product filters to the
remote vector list, remote semantic-FTS list, and SQLite local lexical list
before RRF, then hydrates the fused IDs from SQLite. Hidden or deleted items
never influence ranking. `offline` is a client display state. Sparkle and MCP
use the same remote index and client fusion/visibility contract; MCP still
revalidates authorization before and after every remote await.

## Identity and data flow

The tenant's active identity is represented as an opaque stable ID backed by the
following server-owned tuple:

```text
EmbeddingIdentity {
  id: string                 // immutable per model/policy/dimension choice
  model_slug: string         // exact OpenRouter slug
  dimensions: 1024
  routed_provider: string    // actual provider bound to this identity
  provider_policy_version: string
  provider_zdr: true
  data_collection: "deny"
}
```

The server MUST reject an embedding response unless the vector length is 1024,
all values are finite, the model/identity matches the current tenant identity,
and the policy evidence is current. The caller never chooses an arbitrary
dimension or directly supplies an embedding identity.

For an eligible item, the sequence is:

1. Apply the local privacy decision. A deny/unknown decision has zero network
   path and no retry.
2. For an image, run existing local OCR/sensitive scanning before any upload.
   The image itself may be embedded directly; OCR text remains a local exact
   retrieval signal and an approved redacted semantic derivative only when the
   privacy contract permits it. A joint image/text vector is optional per model.
3. Edge probes the actual OpenRouter route and calls `/api/v1/embeddings` with
   the active model, `dimensions: 1024`, and the adapter wire preferences
   `provider: { zdr: true, data_collection: "deny" }`. These request settings
   are allowed OpenRouter semantics, not evidence that the selected routed
   endpoint complied; actual provider/policy evidence is recorded separately.
   A policy or shape failure is visible, fail-closed, and does not write a
   semantic row.
4. Persist the validated vector with its exact identity and index state. A model
   or policy identity change marks all previous rows stale before new writes and
   creates a resumable rebuild cursor owned by the server boundary.
5. Search creates one text-query vector with the same active identity and
   independently produces server vector, server semantic-FTS, and local
   SQLite lexical lists. The client applies current local visibility/product
   filters to each list, then applies RRF and hydrates the surviving IDs from
   SQLite. Hidden/deleted items never influence ranking.

## Candidate policy

The current official OpenRouter evidence supports a concrete bake-off candidate:
`voyageai/voyage-multimodal-3.5` is described as vectorizing text, images, and
video and lists 2048/1024/512/256 dimensions. `google/gemini-embedding-2` is
described as mapping text and images into one space but lists recommended sizes
of 768/1536/3072, so exact 1024 output must be proven rather than inferred.
OpenRouter's current official search did not establish a Qwen3-VL-Embedding
model page; that candidate is admitted only if the live router exposes the
exact slug and all gates pass. These are candidates, not a selected provider.

The bake-off selection order is:

1. Enumerate the current OpenRouter embedding model/endpoint metadata without
   reading or logging credentials.
2. Filter for text+image inputs, a 1024 output, actual OpenRouter routing, and
   policy evidence for `provider.zdr=true` plus `data_collection=deny`.
3. Run the fixed four-slice retrieval corpus. Every slice independently requires
   Recall@5 >= 0.85, nDCG@5 >= 0.80, and leakage exactly zero; record latency,
   qualified-request cost, and failures per slice/candidate. Overall averages
   are informational and cannot hide a failing slice. JSON validity is not a
   base embedding-candidate gate: set `enhancement_applicable=false` and
   `json_validity_rate=null` unless the optional GPT/VLM structured enhancement
   is enabled. If the optional enhancement is enabled, require JSON validity
   >=99.5% and a positive retrieval delta in addition to the base privacy/ZDR
   and slice gates.
4. Select the lowest-cost candidate among candidates that pass all frozen gates.
   If no candidate passes, WP5 is a hard stop and no index is enabled.

## Rejected designs

- Qwen3 text-only embedding plus a mandatory generated image description cannot
  satisfy one shared text/image space; it is not the WP5 default.
- Comparing vectors from different models, dimensions, provider routes, or
  policy versions is forbidden even if a database cast makes the shapes match.
- A GPT/VLM call for every image is not part of indexing. It is an optional
  enhancement only when a redacted bake-off proves measurable retrieval value.
- MCP does not own an embedding provider or a duplicate index; it reuses the
  same server result and authorization boundary.

## Failure and rebuild shape

Policy failure, unsupported modality, non-1024 output, non-finite value,
identity mismatch, sensitive admission, or stale authorization returns a typed
failure and leaves the source item local. A transient transport error may retry
only inside the server's bounded job policy; it must not create a semantic row
without a matching identity. A rebuild is resumable and idempotent per item and
identity, but old vectors remain stale and ineligible until the new vector is
validated.
