# CloudKit one-time recovery and PowerSync migration

## Status

CloudKit is a legacy recovery source, not a sync authority. WP0 creates no
CloudKit resource, migration code, hosted service, or deletion job. The target
cloud boundary is PowerSync plus Supabase.

The [Cloud Sync and AI Refactor Plan](architecture/PASTEBUDDY_CLOUD_SYNC_AI_REFACTOR_PLAN.md)
controls migration scope and order; this document controls the CloudKit
recovery boundary.

## One-time migration

The migration accepts the newest valid encrypted CloudKit Snapshot available
to the device. It does not merge arbitrary records or run CloudKit and
Supabase as dual authorities.

The fixed order is:

1. Locate and validate the latest Snapshot using the existing local storage
   envelope and integrity checks.
2. Atomically import it into the local PowerSync-managed SQLite database.
3. Persistently freeze CloudKit writes immediately, before filtering or any
   PowerSync/Supabase upload.
4. Apply local content-type, sensitive-content, exclusion, and custom-rule
   decisions. Sensitive or excluded rows remain local and have zero network
   path.
5. If the user has a cloud account and capability, start the normal
   PowerSync path. The newest 100 eligible items are prioritized, then the
   remainder continues resumably under the 5,000-item and 250,000,000-byte
   attachment quotas.
6. Record local-import and cloud-migration markers separately for macOS and
   iOS. Overall migration is successful only when both platform marker pairs
   satisfy their recovery conditions.

If validation or freezing fails, the pre-import SQLite state is preserved and
no upload begins. A missing Snapshot leaves local history untouched. Retrying
the same import is idempotent by package identity and marker state.

Cloud content is service-readable under Supabase Auth and RLS; the migration
does not claim E2EE or add a custom device-key protocol. Existing local
encryption remains a local protection and is not a cloud authority.

## Read-only recovery window

After a successful migration marker, CloudKit is read-only recovery for 90
days:

- normal sync does not write, update, delete, or subscribe to CloudKit records;
- an explicit recovery action still imports through SQLite first;
- newer local or Supabase data cannot be overwritten implicitly;
- deletion after 90 days is a separate explicit user-authorized decision with
  its own confirmation and evidence.

There is no dual-write period and no direct CloudKit-to-UI path.

## Current clipboard sync

Clipboard sync is the encrypted CloudKit private snapshot already implemented
by `CloudKitSyncService`. macOS, iOS, and the keyboard, share, and action
extensions use `CloudKitClipboardSyncSession` when the user has enabled iCloud
sync and the signed CloudKit capability is present. Iroh, its dependency,
pairing state, and UI are removed.

The migration sections above describe the later PowerSync recovery boundary.
They do not keep an Iroh implementation in the tree, and they do not disable
the current CloudKit clipboard sync loop.

Existing CloudKit record factories, snapshots, invitations, and user data
remain as migration inputs. They are not new Supabase schema or sharing
authority.

## WP6 acceptance

WP6 must exercise real signed macOS and iOS apps with real encrypted
Snapshots, relaunch, offline/no-account mode, freeze-before-upload ordering,
marker persistence, quota continuation, and failure recovery. Evidence is
bound to the source commit and build and includes screenshots,
Accessibility trees, relevant window/view frames, and before/after diffs for
the migration UI. Static source assertions and fake transports are not
migration evidence.
