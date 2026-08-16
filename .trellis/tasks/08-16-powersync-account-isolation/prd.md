# Account cache and cloud ID isolation

## Goal

Ensure account A and B have separate deterministic cloud identities and downloaded caches while local-only captures remain device-owned.

## Dependencies

powersync-repository-boundary.

## Requirements

- Cloud ID derivation includes canonical Supabase user identity plus local item identity.
- Logout clears only the active account replica/cache and never local-only history or server data.
- Account switches cannot reuse an old connector, queue entry, checkpoint, or synced row.

## Acceptance criteria

- [ ] The same local item mapped to A and B receives different stable cloud IDs.
- [ ] Logout/relogin removes and restores only the selected account cache while local-only rows persist.
- [ ] Cross-account queries, pending work, and merged views return zero foreign rows.

## Out of scope

- No server deletion on logout.
- No device-global cloud ID or shared account checkpoint.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
