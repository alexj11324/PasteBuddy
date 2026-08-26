# Quota pause and queue settlement

## Goal

Pause cloud admission at 5,000 items or 250,000,000 attachment bytes and settle permanent rejections without blocking unrelated later work.

## Dependencies

powersync-backfill-checkpoint.

## Requirements

- Use server-authoritative rejection classification; local counters are advisory UX only.
- Permanent rejection becomes a durable local-only error and is removed/settled from the upload queue.
- Temporary transport/service failures remain retryable and do not masquerade as quota rejection.

## Acceptance criteria

- [ ] Crossing either quota stops new cloud work while local capture/read remains complete.
- [ ] Deleting cloud data or restoring entitlement resumes from the same checkpoint.
- [ ] A permanently rejected item does not retry forever or block a later valid item.

## Out of scope

- No client-only quota authorization.
- No 4xx infinite retry loop or dropping local content.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
