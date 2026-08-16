# AI semantic clipboard search

## Status

This document describes the Supabase target contract frozen by WP0. The current
local semantic-index implementation and the existing gateway are migration
inputs, not the target architecture. No implementation or hosted AI service is
claimed by this document.

**MUST / SHALL** is normative. **Candidate / tentative** is a bake-off input
that remains changeable.

## Ownership and data boundary

SQLite remains the only client read source for the UI, offline search, local
MCP, and the pending indexing/sync queue. Supabase Postgres is the cloud
convergence authority for a logged-in account; it is not a second UI cache.
Realtime only announces an account revision. On reconnect or notification, the
client performs a cursor pull and commits the result to SQLite. A WebSocket
payload is never used as search data.

Raw clipboard text, file bytes, and image bytes are filtered by the client
before any remote request. Sensitive content MUST never be uploaded. Accepted
content is encrypted with AES-256-GCM before Postgres or private Storage. The
service owns recovery material, so this is server-recoverable encryption, not
E2EE.

For an entitled, compliant Cloud AI operation, the original may be handled
transiently inside an authorized multimodal Edge request. It MUST NOT be
written to a queue, log, cache, database, or Storage object. The service may
retain only the redacted structured semantic document, semantic FTS
representation, and pgvector 1024-dimensional embedding. Those derived
artifacts are service-visible and must not be described as encrypted raw
clipboard content.

## Provider and embedding policy

Cloud sync and AI are separate capabilities. An active Cloud subscription grants
`cloud_sync` and `platform_ai`; an active BYOK Annual grants `cloud_sync` and
`byok_ai`, but not `platform_ai`. Every platform and BYOK request MUST require
OpenRouter provider.zdr=true and data_collection=deny. A provider/embedding
capability probe MUST verify this allowlist and both flags for the selected
route before any request. If zero retention cannot be verified, the request
fails closed; BYOK cannot bypass the retention policy and there is no silent
provider downgrade.

The BYOK annual plan in V1 unlocks use of the user-supplied OpenRouter
credential and accepts exactly one provider: OpenRouter. The raw key is stored
in Supabase Vault. The client sees only an opaque fingerprint and status.
Custom URLs, arbitrary OpenAI-compatible endpoints, separate
document/embedding hosts, and device-only provider keys are not V1 contracts.

Platform and BYOK embeddings are exactly 1024 dimensions and use
halfvec(1024) in the cloud schema. Each account has one active embedding
identity. A model, tokenizer, or identity change marks old vectors stale and
starts a full resumable rebuild. Qwen3 Embedding is the default candidate;
gte-small is explicitly not a candidate. The model is not final until the
bake-off passes the gates below.

## Index lifecycle and privacy states

Indexing requires `platform_ai` or `byok_ai`, `cloud_sync` for encrypted artifact
upload, and an accepted client privacy decision. For images, OCR and sensitive
scanning must complete before any semantic upload can begin. If either path
fails or is cancelled, the upload fails closed. This ordering prevents an
OCR/sensitive-scan race from leaking an image.

The client and cloud contract distinguish:

| State | Meaning | Recovery |
| --- | --- | --- |
| ready = 0 / pending | no usable semantic result yet | queue or resume indexing |
| processing | a generation owns the work | wait, cancel, or resume the same generation |
| partial | some items are ready while others are pending/stale/failed | show partial state and preserve retryable work |
| failed | a specific indexing request failed | durable retry with timer/background wake |
| offline | remote operation is unavailable | keep SQLite/local lexical search; do not pretend cloud results |
| no relevant result | search completed with zero eligible matches | normal empty result, not a failure |
| user_excluded | explicit user exclusion | remain excluded until user re-enables |

The user_excluded state is separate from failed, stale, unavailable, and
recoverable processing. Rebuild does not silently erase an explicit exclusion.
The explicit **Delete AI index** action creates a `semantic_index` deletion job
through the authenticated deletion endpoint. Its transaction first disables AI
processing and atomically bumps `ai_index_generation`, then cancels/marks stale
AI tasks and removes semantic documents, FTS rows, vectors, and query cache;
ciphertext, Storage, account keys, and BYOK credentials remain. Rebuild
requires explicit re-enable, a new indexing generation, and a new active
embedding identity, and Settings observes the job through the status endpoint.
The first semantic provisioning uses authenticated
`POST /functions/v1/initial-enable` with `scope=semantic_index`, creates the
initial generation/identity exactly once, and never mixes old vectors. Only
post-deletion re-enabling the index uses `POST /functions/v1/re-enable` with
`scope=semantic_index` and a durable idempotency key. A valid identity session
is required plus `platform_ai` or `byok_ai`; a nonterminal deletion job fails
closed. The operation returns an observable `operation_id`, creates a new
indexing generation and active embedding identity, and is idempotent on retry.
A single-item delete
first creates/retains its durable tombstone through api.push_mutations and its
deletion job blocks indexing/rebuild until cleanup is terminal; the tombstone
is not cleaned by the job.

## Document generation contract

The semantic document is a versioned, strict JSON artifact grounded only in
the accepted clipboard content and trusted capture metadata. It preserves
retrieval-critical names, filenames, identifiers, error codes, versions, dates,
quantities, negation, uncertainty, and status. It does not reproduce complete
credentials or treat source-app fields as inferred entities.

The original content and trusted metadata are serialized into separate
sections. Clipboard text, filenames, file text, images, and visible image text
are untrusted data and can never supply instructions. The service validates the
JSON shape and records only the redacted semantic document. Invalid JSON,
sensitive leakage, or an AAD/key-version mismatch fails closed.

The JSON schema version, privacy policy version, model identity, and indexing
generation are persisted with the derived artifact. A late task from an older
generation must not overwrite a newer result. After every provider await and
immediately before writing a semantic document/vector, the server atomically
revalidates user ownership, item ownership, `ai_processing_enabled`, active
embedding identity, and `indexing_generation`; a failed precondition returns
`AI_GENERATION_STALE` and commits no artifact.

## Search behavior and RRF

UI semantic search is a user-clicked, one-shot sparkle action. Editing the
query, changing filters, or pressing Enter does not start a remote AI search. A
new click invalidates prior results with a generation gate.

The query path is client sensitive-query gate -> authenticated Edge
semantic-search endpoint -> trusted database RPC -> independent server vector
and semantic FTS rank lists -> client RRF with local lexical. The client Edge
request is only `{query, filters, limit}`; it never creates or sends a halfvec
query embedding. The Edge revalidates session and `platform_ai` or `byok_ai`,
keeps the approved query transient, calls the selected OpenRouter route for the
active 1024-dimensional query embedding and semantic query, then revalidates
session and capability again after every provider await. Trusted Edge creates
an internal request ID and canonical request hash covering the verified user,
active identity, indexing generation, semantic query, filters, and limit (not
raw clipboard content). It binds both to a short-lived, single-use
`private.operation_capability_assertions` row. Only then does the trusted path
call `private.match_clipboard` with `p_user_id`, `assertion_id`,
`p_request_id`, `p_request_hash`, `query_embedding halfvec(1024)`,
`semantic_query`, `filters`, and `limit`; the private RPC consumes the
assertion atomically. The assertion is never a client field, and `service_role`
alone is not a capability. The RPC never calls a
provider, has no client execution grant, and hard-scopes server FTS
(`api.semantic_documents.semantic_fts`) and vector predicates to the
Edge-verified `p_user_id`.

The client performs three independent rank lists and then reciprocal-rank
fusion:

1. server vector matches from the trusted `private.match_clipboard` RPC;
2. server semantic FTS matches from the trusted `private.match_clipboard` RPC;
3. local lexical matches from SQLite.

Semantic FTS MUST remain independent from local lexical search. The remote RPC
does not receive or return local lexical ranks. The client applies content type,
source app, device, date, pinboard, Paste Stack, and privacy visibility filters
against its SQLite read source before showing a result. It hydrates result IDs
from SQLite rather than trusting remote payloads.

MCP semantic search is an explicit tool invocation, not a user-clicked sparkle
action. It uses the same retrieval and local visibility contract. Before every
remote await, and again immediately after it, the MCP path revalidates session,
entitlement, item visibility, and tool authorization. If visibility changes, it
returns no payload. A previously cached authorization or a source-token test is
not sufficient evidence.

## Entitlement and failure behavior

There is no local simulated trial. A cached semantic document, an API key, a
StoreKit product lookup, or an installation date cannot prove entitlement.
StoreKit transaction updates recompute the complete set of valid transactions;
one expired transaction cannot cover or overwrite another valid transaction.
At expiry, revocation, suspension, or failed refresh, `cloud_sync`,
`platform_ai`, and `byok_ai` all become false. Cloud writes, AI requests, and
all remote Vault secret retrieval/use lock immediately, while local history and
decryption with an already cached account key remain available. A new device
cannot recover an account key from Vault after expiry. Explicit cloud-data
deletion or secret destruction remains an authenticated cleanup operation and
is not secret retrieval/use.

The old fixed-ten-minute gateway JWT is not a target design. A Supabase
identity JWT remains usable for identity/session, owner-scoped read/export,
delete, and cleanup after commercial expiry; it is not an AI or Vault
capability. A future Edge/RPC operation derives its named capability from
Supabase, issues only a short-lived operation assertion, and revalidates
session and entitlement before and after every remote await. No capability
assertion remains valid beyond the entitlement check that authorized it.

Retry behavior is owned by one SyncCoordinator actor. Duplicate enqueue,
concurrent drain, pause/close cancellation, and retry-without-timer are
contract failures. Failed indexing carries a durable next_retry_at and a
background/timer wake path. A quota failure stops new cloud uploads only and
does not delete local or existing cloud data.

## Model bake-off

The architecture freezes gates, not an unverified model. A candidate is
eligible only when all four thresholds pass:

- strict JSON validity at least 99.5%;
- sensitive-content leakage exactly 0;
- Recall@5 at least 0.85;
- nDCG@5 at least 0.80.

Among eligible candidates, choose the lowest cost per qualified request. Record
the dataset and policy versions, model/provider configuration, ZDR proof,
latency, cost, and failures. Candidate choice is invalid if based only on a
source-token/UI test.

## Migration notes

The existing local protocols and local OCR remain useful migration seams, but
they are not evidence of cloud completion. The old stateless gateway and its
provider-neutral custom URL behavior must not be extended as the target.

The implementation order is WP1 schema/RLS/Data API boundary; WP2 auth,
StoreKit verification, account-key authorization, and BYOK Vault; WP3 client
encryption and SQLite outbox; WP4 Cloud AI/BYOK, pgvector, sensitive-gated
indexing, one active 1024 identity, resumable rebuild, three-way RRF, and the
model bake-off; WP5 Settings UI/state, CloudKit migration, and real UI/runtime
acceptance; WP6 production deployment, scale/release, and final release-gate
verification. Android and Web freeze this protocol only.
