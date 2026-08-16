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
  [OpenRouter ZDR documentation](https://openrouter.ai/docs/features/zdr).
- BYOK Annual unlocks only the user's OpenRouter credential. The raw key is
  stored in Supabase Vault. A server-only opaque Vault credential
  reference/mapping may connect it to `ai_profiles`; the client and PowerSync
  stream receive only fingerprint and status, never the reference or raw key.
  Custom URLs, arbitrary OpenAI-compatible hosts, and client-side provider keys
  are not supported.
- Qwen3 Embedding is the default candidate at 1024 dimensions. The database
  embedding shape is 1024. Each tenant has one active embedding identity.
  Changing model, tokenizer, or identity invalidates old vectors and requires
  a resumable rebuild.
- Supabase `gte-small` is not adopted for V1: its English-first behavior and
  long-text truncation do not match the Chinese retrieval target. Qwen3 1024
  remains a default candidate only until the fixed bake-off proves it.
- The candidate is not final until the fixed bake-off passes. WP5 chooses the
  lowest cost per qualified request among passing candidates.

## Index and result behavior

Local SQLite remains the source for local lexical search, visibility filters,
and hydration of result IDs. A remote semantic result cannot become a second
UI cache. The UI states distinguish ready=0, offline, partial, failed, no
relevant result, and explicit user exclusion. Exclusion is not a recoverable
failure and is never silently cleared.

Remote semantic search is a one-shot user action: only clicking the sparkle
starts a remote request. Typing, editing filters, and pressing Enter do not
start Cloud AI. Offline lexical search remains available and responsive.

The client fuses three independent rank lists with reciprocal-rank fusion:

1. server vector matches;
2. server semantic FTS matches;
3. local SQLite lexical matches.

Semantic FTS is never folded into the local lexical list. The client applies
local visibility and product filters, then hydrates IDs from SQLite.

MCP semantic search is a separate explicit tool invocation, not a sparkle
side effect. Before and after every remote await it revalidates the current
session, entitlement, MCP permission, and item visibility. If any check
changes, no payload is returned. Cached authorization and source-token tests
are not sufficient.

## Index lifecycle and deletion

Indexing requires the named AI capability, an accepted privacy decision, and
the cloud capability needed to store an approved derivative. For images,
OCR and sensitive scanning finish before any AI upload; cancellation or
failure blocks the upload.

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

A candidate is eligible only when all thresholds pass:

- strict semantic-document JSON validity at least 99.5%;
- sensitive-content leakage exactly 0;
- Recall@5 at least 0.85;
- nDCG@5 at least 0.80.

The report records dataset version, privacy/policy version, model and
provider configuration, ZDR proof, latency, cost, and failure counts.
Candidate selection from a source-token or UI test alone is invalid.

## WP5 implementation and evidence boundary

WP5 owns the formal model adapter, policy probe, Vault integration, semantic
document shape, vector/FTS query, RRF implementation, MCP revalidation,
retry/readiness states, UI sparkle path, and the real macOS/iOS acceptance.
It must preserve zero-network sensitive behavior and attach network,
database, Sentry-redaction, screenshot, Accessibility, and runtime-frame
evidence. Until those checks pass, this document is a frozen decision, not a
claim of working Cloud AI.
