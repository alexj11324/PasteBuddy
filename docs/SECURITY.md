# PasteBuddy security and privacy contract

## WP0 posture

Clipboard history is high-sensitivity user data. This document freezes the
PowerSync/Supabase threat boundary; it does not claim that a hosted project,
SDK adapter, policy, or deletion worker is deployed.

The [Cloud Sync and AI Refactor Plan](architecture/PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md)
controls implementation scope and order. This document controls the security
and privacy boundary.

The cloud design is explicitly not end-to-end encryption. Accepted cloud
content is service-readable under Supabase Auth, RLS, and private Storage.
TLS and provider-managed encryption at rest are platform protections. WP0
does not design a device-proof exchange, ECDH enrollment, or
server-recoverable AES-GCM envelope.

## Zero-network privacy boundary

The client privacy gate runs before capture handoff, PowerSync upload,
attachment upload, OCR-derived AI work, and semantic search. Sensitive text,
credentials, tokens, private keys, one-time codes, payment data, content
blocked by a user rule, and user-excluded content MUST never leave the device.
They are not sent to PowerSync, Supabase, OpenRouter, RevenueCat, or Sentry.
An unavailable or ambiguous decision fails closed.

Extensions write only an encrypted App Group handoff after the same decision.
They do not open a network connection. The main app imports the handoff into
the single PowerSync SQLite authority. The exact local encryption/Keychain
adapter is a WP1 hard-stop check, not a new wire format.

No-account mode remains fully local. Local encrypted storage and Keychain
protection remain useful local controls, but they do not authorize cloud
access or change the cloud-readable, non-E2EE product promise.

## Supabase boundaries

- Supabase Auth supplies the tenant identity. Every domain table has a
  user_id and deny-by-default RLS tied to auth.uid().
- Direct anonymous or unrestricted table CRUD is forbidden. Business actions
  pass through the PowerSync upload boundary or authenticated Edge Functions.
- The Storage bucket is private, owner-scoped, and not publicly listable.
  Asset access uses the proven helper or exact-object signed URL path. URLs
  and tokens are not logged or persisted.
- Supabase Vault stores the raw BYOK OpenRouter secret only. A server-only
  opaque Vault credential reference/mapping may connect it to `ai_profiles`;
  the client and PowerSync stream receive only fingerprint and status, never
  the reference, raw key, or Vault payload.
- Edge Functions own authenticated provider calls and fixed cleanup actions.
  Queues/Cron may wake fixed jobs. WP0 does not assume delivery or retry
  semantics without WP1 evidence.
- Existing Sentry receives bounded diagnostics and redacted identifiers only.
  Clipboard content, sensitive query text, tokens, and keys are prohibited.

Cloud quotas are 5,000 cloud clipboard items and 250,000,000 attachment bytes.
A quota failure stops new cloud upload and preserves local and existing cloud
data. It is not permission to delete or silently drop history.

## Auth and commercial policy

The user signs in before purchase. The Supabase UUID is the RevenueCat App
User ID. Canonical RevenueCat CustomerInfo is reconciled after purchase,
restore, update, expiry, and revoke; Supabase entitlements authorize cloud
operations. A local trial, cached receipt, installation date, or API key is
never entitlement evidence.

Cloud, platform AI, and BYOK are separate capabilities. Expiry, revocation,
suspension, or failed refresh disables them while local capture, history,
offline lexical search, and cached local decryption remain available. An
invalid Auth session is denied, including for cleanup.

## AI boundary

OpenRouter is the only V1 provider route. Platform and BYOK requests require
verified provider.zdr=true and data_collection=deny. If the zero-retention
policy cannot be proved, the request fails closed. BYOK cannot bypass that
policy or choose a custom host. The policy reference is the official
[OpenRouter ZDR documentation](https://openrouter.ai/docs/features/zdr).

Qwen3 Embedding is the default 1024-dimensional candidate; one active
embedding identity exists per tenant. Semantic derivatives are service
readable, never sensitive originals. The remote UI path starts only from an
explicit sparkle click; offline lexical search remains local. MCP is an
explicit tool action and revalidates session, entitlement, tool permission,
and item visibility immediately before and after every remote await.

## Fixed deletion and verification

Supported deletion scopes are item, semantic index, all cloud data, account,
and BYOK credential. The fixed process is:

1. Authenticated confirmation creates or returns one idempotent request.
2. For all-cloud, `cloud_epoch` increments and cloud writes close.
3. The fixed all-cloud order is semantic/vector, Storage, clipboard, AI
   profile, then Vault. A separate negative query covers each class.
4. It verifies tenant ownership and requires all deletable cloud
   content/AI/asset/domain rows to be empty before `succeeded`; normal-login
   profiles/entitlements and deletion-request/status/audit metadata remain for
   `all_cloud`. Storage, vector, semantic, and Vault must be empty; otherwise
   the request remains visible as an actionable failure.
5. Item deletion writes `deleted_at` before asynchronous Storage and
   semantic/vector cleanup. Stale devices and old-epoch AI/asset work cannot
   resurrect or commit the item. Account deletion, not `all_cloud`, clears the
   account scope; Vault/account removal is last after proof.

Deleting one item must not resurrect it on a stale device. Deleting the AI
index preserves clipboard rows, attachments, local history, and BYOK. A
nonterminal request blocks recreation or rebuild; retries are idempotent.
Deletion remains available after commercial expiry only with a valid Auth
session. No cleanup path retrieves a secret.

## Runtime evidence

WP1 must prove tenant A/B isolation, zero-network sensitive content,
encrypted App Group handoff, Keychain fail-closed behavior, quotas, process
kill/reconnect, and the single PowerSync owner. WP5/WP6 must prove ZDR
failure, BYOK Vault redaction, MCP revalidation, deletion verification,
CloudKit freeze ordering, and real macOS/iOS UI behavior. Evidence must bind
runtime environment, source commit, entitlement/privacy state, screenshots,
Accessibility trees, and relevant frames without storing sensitive payloads.
