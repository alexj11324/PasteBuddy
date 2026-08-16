# CloudKit recovery and Supabase migration

## Status

CloudKit is a legacy recovery source for the Supabase migration, not the target
sync authority. This document freezes the one-time import and retirement
contract. Existing CloudKit code and user data are not deleted by WP0, and no
CloudKit resource is created or modified here.

The target has one cloud convergence authority: Supabase Postgres. SQLite
remains the only client read source for UI, offline use, and the sync queue.
There is no CloudKit/Supabase dual-write period.

## Security language

CloudKit's latest snapshot is already encrypted when imported. The target
client filters restored content, encrypts accepted mutations with AES-256-GCM,
and uploads ciphertext to Supabase Postgres or private Storage. Because the
server hosts recovery material, the target term is server-recoverable
encryption. It is not end-to-end encryption and must not be described as E2EE.

Plaintext fallback is forbidden. A corrupted, undecryptable, wrong-key-version,
or wrong-AAD snapshot fails closed and leaves the existing SQLite history
unchanged. No plaintext temporary file, log, notification, or CloudKit record
may be used to recover from the error.

## One-time import contract

The migration imports the newest valid encrypted Snapshot available to the
device, not an arbitrary record and not a merge of independent CloudKit writes.
The import sequence is:

1. discover the latest encrypted Snapshot and verify container, envelope,
   schema, key version, AAD, and integrity;
2. merge it atomically into the local SQLite snapshot;
3. immediately and persistently freeze CloudKit writes, before any Supabase
   upload or other cloud mutation;
4. run the normal local content-type, sensitive-content, and custom-rule
   filters against the restored SQLite data;
5. if this is a never-provisioned account, create separate device-held P-256
   signing and key-agreement keys,
   obtain a single-use `purpose=register` challenge from
   `POST /functions/v1/device-proof-challenge`, and complete authenticated
   `POST /functions/v1/initial-enable` for `scope=cloud_sync` with platform,
   both public keys, the byte-exact v1 register context hash, challenge, and
   IEEE-P1363 signature fields defined in the schema contract.
   Then call
   `POST /functions/v1/account-key-delivery`; only after its device-bound
   envelope is decrypted and stored may the client enqueue accepted,
   AES-256-GCM-encrypted mutations for Supabase. Otherwise retain them locally
   for a later eligible sync;
6. drain through the single SyncCoordinator using mutation IDs and cursor
   revisions;
7. record separate local-import and cloud-migration markers for the current
   macOS or iOS platform; the overall migration succeeds only after both
   platform marker pairs satisfy recovery conditions.

The freeze marker is durable and includes the import package identity, snapshot
schema version, local SQLite revision, platform, and completion time. A local
import marker and a cloud migration marker are written only after the freeze
is persisted and their respective step succeeds. A failed import or failed
freeze must not begin upload. There is no dual-write interval.

If a user has no valid CloudKit Snapshot, the migration leaves local history
untouched and starts a new Supabase account/device path. If the same import is
retried, package identity and generation make it idempotent. The client never
uses a Realtime event as proof that import completed.

## Read-only recovery window

CloudKit recovery is read-only for 90 days after the successful marker. During
that period it may be used to re-read the latest encrypted Snapshot for an
explicit recovery action, but:

- no CloudKit record is written, updated, or deleted by normal sync;
- no new CloudKit subscription or shared history write is added;
- restored data still enters SQLite first and then follows the Supabase
  encryption/filtering boundary;
- a recovery action cannot overwrite newer SQLite or Supabase revisions without
  an explicit conflict/recovery decision.

Deletion after the 90-day window is a separate, explicit, user-authorized
concern. It must have its own review, confirmation, audit event, and recovery
policy. It is not an automatic side effect of import and is not implemented
by this contract.

## Failure and lifecycle rules

- CloudKit account unavailable, `cloud_sync` missing, or key unavailable:
  keep local mode fully usable and show a recoverable migration state.
- Snapshot integrity, key version, or AAD failure: fail closed; preserve the
  pre-import SQLite state and expose a safe diagnostic.
- Duplicate import or concurrent import: serialize by generation and package
  identity; cancel late work when the app closes or migration is paused.
- Upload quota reached: stop new Supabase uploads only; never delete local or
  existing cloud data.
- Attachment import: use the authenticated Edge reserve signer, upload
  ciphertext, then use the Edge commit verifier; an uncommitted object older
  than 24 hours is cleanup-eligible. SQL/Data API RPCs never sign URLs.
- Reconnect or Realtime notification: cursor pull from Supabase, never direct
  CloudKit or WebSocket record merge.

The only synchronization owner is SyncCoordinator. Failed work stores a durable
next_retry_at and has a timer/background wake path. A retry that depends on a
future user action, a duplicate drain, or an uncancelled generation is a
migration contract failure.

## Legacy CloudKit boundary

The old CloudKit record factory, private database snapshot transport, and
shared-pinboard invitation records are preserved as migration inputs only.
They must not be extended into a second long-term history authority. New
Supabase schema/API contracts are documented in
SUPABASE_SCHEMA_API_CONTRACT.md.

CloudKit's old shared-pinboard path does not become a Supabase sharing protocol
by implication. Any future sharing migration needs a separate, explicit
security review and must preserve encrypted data and participant boundaries.

Iroh implementation, dependencies, and user pairing data remain in place, but
the unified PasteBuddyFeatureAvailability.irohClipboardSync capability remains
off across macOS, iOS, and extensions. This migration does not delete or revive
Iroh.

## Platform acceptance

V1 runtime targets macOS and iOS. Android and Web only consume the frozen
protocol. Before a migration is called successful, each platform must prove:

- a real signed/runtime app imports a real encrypted Snapshot into SQLite;
- the platform's local-import and cloud-migration markers survive relaunch;
- the overall success state is withheld until both macOS and iOS marker pairs
  satisfy recovery conditions;
- CloudKit writes are blocked before filtering or any Supabase upload;
- filtered/encrypted mutations reach Supabase through the real coordinator;
- an offline/no-account path remains complete;
- a failure leaves the old SQLite state intact and visibly recoverable.

Static source assertions, a fake transport, or a test that only inspects
source-token strings cannot replace real macOS/iOS runtime evidence.
