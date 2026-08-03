# AI Semantic Clipboard Search

PasteBuddy's AI feature is a local derived index over clipboard history. It is not a user-profile or conversational memory system.

The implementation is native PasteBuddy code rather than Mem0: GRDB/SQLite already owns clipboard lifecycle, deletion, scope, and MCP access, while provider-neutral Swift protocols keep Cloud, BYOK, and a future local model interchangeable.

## Data boundary

- Clipboard items, semantic documents, Float16 embeddings, query cache, exclusions, failures, and the indexing outbox are stored in the existing local GRDB/SQLite database. Dense ranking uses Accelerate/vDSP cosine on Apple platforms and semantic FTS5 participates in reciprocal-rank fusion.
- The gateway is stateless. It accepts bounded inference requests, returns the result, and has no persistence integration.
- BYOK requests go directly from the app to OpenAI, Gemini, or an OpenAI-compatible endpoint. API keys are stored with `AfterFirstUnlockThisDeviceOnly` Keychain accessibility and are never sent to PasteBuddy's gateway.
- Eligible images are resized, metadata-stripped, and sent directly to a multimodal model. OCR is not a prerequisite and OCR text is not included in the inference request; existing local OCR is used only for the deterministic sensitive-content deny check.
- Deterministic privacy policy and sensitive-text detection run before upload. Provider accounts must be configured for zero data retention.
- Gateway authorization uses App Store signed app/entitlement transactions and short-lived feature JWTs. PasteBuddy does not create an account system.

## User controls

- AI Search is opt-in and requires a verified App Store introductory trial or an active recurring subscription. There is no local simulated trial and no lifetime product.
- BYOK Annual unlocks BYOK only. Cloud Monthly and Cloud Annual unlock both the stateless PasteBuddy Cloud route and BYOK. Every capability locks immediately at subscription expiry; local derived data remains deletable.
- All eligible new items are queued automatically; existing history is backfilled asynchronously.
- Pausing keeps the current local index searchable but stops new processing.
- “Remove from AI Search” deletes one item's derived document and embedding and creates a local suppression record. “Add to AI Search” removes that suppression and queues the item again.
- Rebuild preserves per-item exclusions. Delete AI Index removes all derived AI data and turns the feature off without deleting clipboard history.

## Search behavior

The sparkle button performs a one-shot semantic search for the current query. Results use reciprocal-rank fusion of the existing lexical search and local embedding similarity while preserving content type, source app, device, date, pinboard, and Paste Stack scope. Editing the query or filters invalidates the prior AI result through a generation gate.

The existing local MCP service exposes the same semantic search path when semantic indexing is enabled. It queries the on-device SQLite index through PasteBuddy's shared search contracts; it does not upload clipboard history or introduce a second persistence layer.

## Semantic document prompt contract

Cloud and BYOK document generation use the same versioned `semantic-index-v2` contract. Stable indexing policy is sent as a system instruction, while trusted capture metadata and untrusted clipboard content are serialized into separate sections of the user payload. Clipboard text, filenames, file text, images, and visible image text can never supply instructions.

The contract is evidence-grounded and preserves retrieval-critical names, filenames, identifiers, error codes, versions, dates, quantities, negation, uncertainty, and status. `capturedAt` is available for explicit relative-date interpretation, source-app fields remain provenance rather than inferred entities, and complete credentials must not be reproduced in derived fields. Responses contain one strict JSON document with no additional keys. This derived document remains an item-level search artifact; it is not an agent memory, user profile, persona, or cross-item ADD/UPDATE/DELETE system.

## Future local models

The pipeline depends on `SemanticDocumentGenerating` and `SemanticEmbeddingProviding`, not a cloud SDK. Cloud and BYOK are already adapters behind those protocols. A future MLX implementation can replace either provider without changing SQLite schema, search fusion, deletion, UI, or MCP contracts.
