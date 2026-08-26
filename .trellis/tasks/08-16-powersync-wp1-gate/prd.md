# WP1 integration and independent review

## Goal

Bind all leaf evidence to exact commits, run one concentrated independent Sol review, and issue the WP1 Pass or Hard Stop decision.

## Dependencies

All prior WP1 children.

## Requirements

- Coordinator first verifies every child status, commit, command output, hosted environment, and residual risk.
- One read-only Sol reviewer receives the final diff/spec/evidence bundle and returns one consolidated finding set.
- Only verified fixes return to the owning leaf; the final Gate does not absorb implementation changes.

## Acceptance criteria

- [ ] All required matrix rows have reproducible evidence and no unresolved P0/P1 finding.
- [ ] Git history maps each leaf to a focused commit and the worktree contains no unowned change.
- [ ] Coordinator records WP1 Pass or Hard Stop; only Pass permits WP2 planning.

## Out of scope

- No business-code fix in the review task.
- No self-certification by the implementer or compilation-only Pass.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
