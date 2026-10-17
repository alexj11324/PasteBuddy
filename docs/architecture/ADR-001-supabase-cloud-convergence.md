# ADR-001: Supabase cloud convergence with a local SQLite read source

## Status

Superseded by ADR-002 (2026-08-16). This file is retained as a historical
record only. It is not an active implementation contract.

## Historical record

On 2026-08-15, WP0 proposed a custom Supabase convergence protocol around a
local SQLite read source. The proposal included client-owned push/pull,
revisions and cursors, mutation counters and reset fences, a generic deletion
worker, device proof and key-delivery cryptography, service-recoverable
AES-GCM envelopes, and a stateless gateway boundary.

That proposal was superseded because it made the most failure-sensitive parts
of synchronization and device security PasteBuddy-owned protocol surface. It
also described behavior that had not been proved with a formal Swift SDK,
macOS/iOS runtime, or a live Supabase project. The old contract therefore must
not be implemented, extended, or used to infer a hosted service.

ADR-002 chooses PowerSync for local-first replication, Supabase for the
backend boundary, RevenueCat for commercial identity, and managed platform
security primitives. It defines the smaller WP0 decision and sends SDK,
concurrency, migration, and runtime questions to the later gates.

## Scope of this historical note

- Existing code, local data, and CloudKit inputs are not deleted by
  superseding this ADR. A later explicit removal deleted Iroh clipboard sync;
  this historical note does not require Iroh to remain in the tree.
- Names, RPC shapes, crypto wire formats, revision/cursor/counter/fence
  semantics, and phase protocols from the former proposal are not active.
- No implementation, migration, hosted resource, secret, or acceptance result
  is implied by this record.

See [ADR-002](ADR-002-powersync-supabase-convergence.md) for the current
architecture decision.
