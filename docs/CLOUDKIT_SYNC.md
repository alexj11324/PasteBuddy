# CloudKit Sync Plan

PasteBuddy is local-only by default. CloudKit sync and shared pinboards must be
explicitly configured before any upload path is allowed.

## Current Implementation

- `SyncConfiguration` stores sync provider, CloudKit container identifier,
  end-to-end key hierarchy version, Apple capability status, and shared
  pinboard opt-in.
- `SyncReadiness` blocks upload unless CloudKit sync is explicitly enabled,
  a container identifier is present, an end-to-end key hierarchy version is
  present, and the signed app has the CloudKit capability.
- `CloudSyncPreflightReport` turns readiness, sharing state, plaintext
  downgrade prevention, first-sync state, and latest merge conflicts into
  user-facing diagnostics with recovery recommendations.
- `CloudSyncPackageBuilder` rejects blocked sync states and produces a
  `CloudSyncUploadPackage` containing an encrypted snapshot envelope plus
  non-sensitive routing metadata.
- `CloudSyncRemoteRecord` is the transport boundary. It carries only encrypted
  snapshot data plus non-sensitive routing metadata.
- `CloudKitRecordFactory` converts between `CloudSyncUploadPackage`,
  `CloudSyncRemoteRecord`, and `PasteBuddyEncryptedSnapshot` `CKRecord`
  instances.
- `CloudKitSyncService` builds encrypted upload packages, saves encrypted
  remote records through an injected transport, fetches the latest encrypted
  record, and imports it through the merge pipeline.
- `CloudKitRemoteRecordTransport` defaults to the user's private CloudKit
  database for history and pinboard sync. Public/shared database usage is
  reserved for explicit shared-pinboard invitation routing, never raw clipboard
  history.
- Tests use an in-memory transport so encrypted upload/download, no-record
  recovery, and merge rules stay verifiable without an iCloud account.
- `CloudSyncPackageImporter` decrypts an encrypted package and merges remote
  history/pinboard data into the local snapshot while keeping device-local
  privacy and app settings unchanged.
- Sync import records added/updated entities, kept-local conflict resolutions,
  last imported package ID, and conflict count for recovery/troubleshooting UI.
- When no encrypted remote record exists, download returns no result and leaves
  local encrypted history untouched; the next upload/download can recover
  without writing plaintext temporary files.
- Settings surfaces the preflight summary and each diagnostic finding without
  requiring real iCloud credentials in SwiftPM debug builds.
- Shared pinboards cannot be enabled while sync readiness is blocked. Once
  enabled, pinboards can store encrypted sharing metadata, owner state,
  invitation/link access mode, participant permissions, and stop-sharing state.
- `PinboardShareKeyExchangeService` creates a Curve25519 owner/participant key
  agreement flow and stores only wrapped board keys, public keys, and
  fingerprints in the encrypted snapshot.
- `PinboardShareInvitationService` publishes public identities, creates
  recipient-scoped invitation packages, accepts invitations by unwrapping the
  board key locally, and exposes an injected delivery transport seam. Invitation
  packages contain public identities, permissions, fingerprints, and wrapped
  board keys, not plaintext pinboard contents or private key material.
- `CloudKitPinboardShareInvitationTransport` maps public identities and
  invitation packages to CloudKit records through
  `CloudKitPinboardShareRecordFactory`, so production sharing can use the same
  injected delivery seam as tests.
- The same factory creates recipient-scoped `CKQuerySubscription` records for
  invitation delivery. Subscription notifications are silent
  content-available pushes; user-visible notification text must be generated
  locally after fetching and accepting encrypted invitation packages.
- `PinboardShareInvitationInboxRefreshService` turns a silent push/background
  refresh into a recipient-scoped invitation fetch and writes pending
  invitations to the encrypted snapshot inbox. Inbox entries track pending,
  accepted, rejected, and expired states so recovery UI can be built without
  using plaintext temporary files.
- `CloudKitPinboardShareInvitationNotificationHandler` validates CloudKit
  invitation subscription IDs against the current device public-key fingerprint
  before refreshing the encrypted inbox. Notifications for other devices are
  ignored locally.
- Plaintext fallback is not supported by the model.

## Universal Clipboard Coexistence

PasteBuddy sync does not replace or proxy Apple's Universal Clipboard. The app
captures local pasteboard changes into encrypted history, then syncs that
encrypted PasteBuddy snapshot through the user's private CloudKit database only
after explicit opt-in and readiness checks. If Universal Clipboard also places a
nearby-device copy on the local pasteboard, PasteBuddy treats it as an ordinary
local capture subject to the same privacy rules, deduplication, OCR, retention,
and encryption pipeline.

## CloudKit Record Schema

### Encrypted Snapshot

Record type: `PasteBuddyEncryptedSnapshot`

- `packageID`: UUID string
- `createdAt`: package creation date
- `containerIdentifier`: CloudKit container identifier
- `schemaVersion`: local snapshot schema version
- `keyHierarchyVersion`: end-to-end key hierarchy version
- `envelopeVersion`: encrypted envelope version
- `envelopeAlgorithm`: encrypted envelope algorithm
- `keyID`: key identifier only, not key material
- `encryptedSnapshot`: JSON-encoded encrypted envelope

### Shared Pinboard Public Identity

Record type: `PasteBuddyPinboardShareIdentity`

- `identityID`: UUID string
- `displayName`: user/device display name
- `publicKeyData`: Curve25519 public key bytes
- `publicKeyFingerprint`: SHA-256 fingerprint of the public key
- `createdAt`: identity creation date
- `publicIdentityData`: JSON-encoded `PinboardSharePublicIdentity`

### Shared Pinboard Invitation

Record type: `PasteBuddyPinboardShareInvitation`

- `invitationID`: UUID string
- `pinboardID`: UUID string
- `participantID`: UUID string
- `permission`: `readOnly` or `canEdit`
- `ownerPublicKeyFingerprint`: owner public key fingerprint
- `recipientPublicKeyFingerprint`: recipient public key fingerprint, used for
  invitation lookup
- `boardKeyFingerprint`: SHA-256 fingerprint of the unwrapped board key
- `createdAt`: invitation creation date
- `expiresAt`: optional expiration date
- `invitationPackageData`: JSON-encoded `PinboardShareInvitationPackage`

Invitation records must not include pinboard item contents, unwrapped board
keys, private key material, raw share-link tokens, or plaintext search/OCR data.

### Shared Pinboard Invitation Subscription

Subscription type: `CKQuerySubscription`

- Record type: `PasteBuddyPinboardShareInvitation`
- Predicate: `recipientPublicKeyFingerprint == <local public key fingerprint>`
- Subscription ID prefix: `PasteBuddyPinboardShareInvitation.`
- Options: fires on record creation and update
- Notification: silent `content-available`; no alert body, clipboard text,
  pinboard name, OCR text, board key, or private key material

### Local Encrypted Invitation Inbox

Snapshot field: `pinboardInvitationInbox`

- Stored inside the AES-GCM encrypted local snapshot
- Contains pending invitation packages plus local status, received date,
  status-updated date, and local error message
- Status values: `pending`, `accepted`, `rejected`, `expired`
- Must not be mirrored into plaintext files, logs, notification bodies, or crash
  reports

## Required Apple Configuration

1. Create an iCloud container, for example `iCloud.com.alexjiang.PasteBuddy`.
2. Add iCloud + CloudKit capability to the signed macOS target.
3. Add matching entitlements when producing a signed app bundle.
4. Provide a matching macOS provisioning profile through
   `PASTEBUDDY_PROVISIONING_PROFILE`; `script/build_and_run.sh` applies the
   CloudKit entitlements only when that profile is present.
5. Encrypted history sync uses the private CloudKit database and a symmetric
   key stored in synchronizable iCloud Keychain. Users must enable iCloud
   Keychain on every participating device.
6. Deploy the CloudKit public database schema for public identities and
   invitation packages, then wire signed-app identity, push notification
   entitlements/background modes, system notification callback registration,
   account error handling, and signed-app account/corruption/lost-key recovery
   UI before sending real shared-pinboard invitations.
7. Add account/corruption/lost-key recovery UI before treating shared pinboard
   invitations as production-ready.

The signed entitlement file is `Support/Entitlements/PasteBuddy.entitlements`.

## Security Rules

- Upload only encrypted record payloads.
- Use the user's private CloudKit database for encrypted history/pinboard sync.
  Vendor servers must not receive clipboard history, OCR metadata, search
  indexes, or pinboard contents.
- CloudKit adapter code must accept `CloudSyncRemoteRecord` or
  `CloudSyncUploadPackage`, not raw `PasteBuddySnapshot` or `ClipboardItem`
  values.
- Do not write a plaintext search index to CloudKit.
- Do not sync OCR metadata outside the encrypted payload.
- Do not send real shared-pinboard invitations until signed-app identity, the
  CloudKit public-key directory schema, invitation delivery subscription
  deployment, signed-app push/background registration, and account/corruption
  recovery UX are wired around the local invitation inbox/key exchange model.
- Do not silently downgrade to plaintext if CloudKit, keys, or entitlements are
  missing.
