# AI semantic clipboard search

## WP0 status

This document freezes product and privacy decisions for the Cloud AI work.
It does not claim that a model, provider, PowerSync adapter, Edge Function,
pgvector index, or UI path exists. Implementation details and all runtime
evidence belong to WP5.

The [Cloud Sync and AI Refactor Plan](architecture/PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md)
controls implementation scope and order. This document controls the AI product
and privacy decisions within that scope.

## Privacy is the first boundary

The local privacy decision runs before App Group handoff, PowerSync upload,
attachment upload, OCR-derived AI work, or a search request. Sensitive and
user-excluded content has zero network path. It remains local and is never
sent to Supabase, OpenRouter, RevenueCat, or Sentry. An unavailable or
ambiguous privacy decision fails closed.

Cloud AI content is service-readable under Supabase Auth, RLS, and private
Storage. This is not E2EE. The service may retain only the approved
service-visible semantic derivative; it must not retain sensitive original
content. WP5 must prove the boundary with network and storage evidence.

## Provider, BYOK, and embedding decisions

- OpenRouter is the only V1 AI route. Platform and BYOK requests require a
  verified provider zero-data-retention policy: provider.zdr=true and
  data_collection=deny. Missing or unverifiable policy fails closed; BYOK
  cannot bypass it. The policy reference is the official
  [OpenRouter ZDR documentation](https://openrouter.ai/docs/guides/features/zdr).
- BYOK Annual unlocks only the user's OpenRouter credential. The raw key is
  stored in Supabase Vault. A server-only opaque Vault credential
  reference/mapping may connect it to `ai_profiles`; the client and PowerSync
  stream receive only fingerprint and status, never the reference or raw key.
  Custom URLs, arbitrary OpenAI-compatible hosts, and client-side provider keys
  are not supported.
- The Edge-to-OpenRouter embeddings request sends `dimensions: 1024` and
  `provider: { zdr: true, data_collection: "deny" }` as routing constraints
  supported by the official request schema. Those fields are not evidence that
  a routed endpoint complied; the actual provider and current policy evidence
  must be recorded and verified. A fallback/provider-policy change creates a
  new identity or fails closed.
- Text items, image items, joint image/text items, and text queries use one
  active multimodal embedding identity per tenant and one shared 1024-dimensional
  space. An identity includes the exact OpenRouter model slug, routed provider,
  policy version, and dimension. Different identities are never compared; an
  identity change marks every old vector stale and requires a resumable rebuild.
- The concrete bake-off candidate is `voyageai/voyage-multimodal-3.5` because
  the current official OpenRouter model page describes text/image/video
  embeddings and lists 1024 dimensions. `google/gemini-embedding-2` and any
  Qwen3-VL-Embedding slug are conditional candidates only: OpenRouter routing,
  exact 1024 output, cross-modal behavior, and ZDR evidence must be proven at
  runtime before inclusion. No side-conversation example selects a model.
- An image may receive a direct image or joint image/text vector. Local OCR,
  server semantic FTS, and local lexical search remain independent exact-text,
  code, and identifier paths. GPT/VLM generation is optional only for a
  measured summary/structured-extraction or retrieval enhancement; it is not a
  mandatory per-image indexing step.
- Supabase `gte-small` and Qwen3 text-only embeddings are not V1 multimodal
  candidates. The selected candidate is not final until the fixed bake-off
  passes; WP5 chooses the lowest cost per qualified request among passing
  candidates.

## Index and result behavior

Local SQLite remains the source for local lexical search, visibility filters,
and hydration of result IDs. The Edge response contains only independent server
vector and semantic-FTS lists plus identity/stale/index status; it never returns
local lexical results or final RRF IDs. The client composes the remote lists with
its SQLite local lexical list, applies current visibility/product filters to all
three before RRF, and hydrates the surviving IDs. Hidden/deleted items cannot
influence ranking. `offline` is a client display state, not an Edge response
state. A remote semantic result cannot become a second UI cache. The UI states
distinguish ready=0, offline, partial, failed, no relevant result, and explicit
user exclusion. Exclusion is not a recoverable failure and is never silently
cleared.

Remote semantic search is a one-shot user action: only clicking the sparkle
starts a remote request. Typing, editing filters, and pressing Enter do not
start Cloud AI. Offline lexical search remains available and responsive.

The client fuses three independent rank lists with reciprocal-rank fusion:

1. server vector matches;
2. server semantic FTS matches;
3. local SQLite lexical matches.

Semantic FTS is never folded into the local lexical list. The client applies
current local visibility and product filters independently to every list, then
applies RRF and hydrates IDs from SQLite. Sparkle and MCP share this same remote
index and client fusion contract.

MCP semantic search is a separate explicit tool invocation, not a sparkle
side effect. Before and after every remote await it revalidates the current
session, entitlement, MCP permission, and item visibility. If any check
changes, no payload is returned. Cached authorization and source-token tests
are not sufficient.

## Index lifecycle and deletion

Indexing requires the named AI capability, an accepted privacy decision, and
the cloud capability needed to store an approved derivative. For images,
OCR and sensitive scanning finish before any AI upload; cancellation or
failure blocks the upload. A direct image/joint vector may proceed only after
that gate, and a generated description is optional rather than an indexing
precondition.

Delete AI index is the fixed semantic_index deletion action. It removes only
semantic documents, FTS, vectors, and AI work after disabling indexing;
clipboard rows, attachments, local history, account state, and BYOK
credentials remain. Rebuild requires explicit re-enable and a new active
embedding identity. Item and account deletion follow the common fixed
deletion process. Late work must not recreate a deleted derivative.

The first semantic enable and post-deletion re-enable are authenticated
business actions owned by Supabase. WP5 decides the concrete PowerSync/Edge
adapter and status presentation; WP0 does not define a custom authorization
or concurrency wire format.

## Fixed bake-off

A pure multimodal embedding candidate is eligible only when each of the four
required slices independently passes all base thresholds:

- text→text: Recall@5 >= 0.85, nDCG@5 >= 0.80, sensitive leakage = 0;
- text→image: Recall@5 >= 0.85, nDCG@5 >= 0.80, sensitive leakage = 0;
- image→image: Recall@5 >= 0.85, nDCG@5 >= 0.80, sensitive leakage = 0;
- screenshot OCR exact retrieval: Recall@5 >= 0.85, nDCG@5 >= 0.80,
  sensitive leakage = 0.

Latency, qualified-request cost, and failures are recorded per slice and
candidate. Overall averages are reported but cannot rescue a failing slice.
Pure embedding candidates set `enhancement_applicable=false` and do not emit
JSON; `json_validity_rate` is therefore nullable and is not a base admission
gate. If an optional GPT/VLM structured semantic-document enhancement is
enabled, it additionally requires JSON validity >=99.5%, a positive retrieval
delta, and the same privacy/ZDR gates.

The report has separate text→text, text→image, image→image, and screenshot OCR
exact-retrieval slices. Each slice records Recall@5, nDCG@5, latency, cost per
qualified request, and sensitive leakage (which must be zero); it also records
dataset version, privacy/policy version, model and provider configuration, ZDR
proof, and failure counts. Averages cannot hide a failing slice.
Candidate selection from a source-token or UI test alone is invalid.

## WP5 implementation and evidence boundary

WP5 owns the formal multimodal model adapter, policy probe, Vault integration,
semantic-document shape and identity, direct/joint image vector path,
vector/FTS query, RRF implementation, MCP revalidation, retry/readiness states,
optional generative enhancement gate, UI sparkle path, and the real macOS/iOS
acceptance.
It must preserve zero-network sensitive behavior and attach network,
database, Sentry-redaction, screenshot, Accessibility, and runtime-frame
evidence. Until those checks pass, this document is a frozen decision, not a
claim of working Cloud AI.
