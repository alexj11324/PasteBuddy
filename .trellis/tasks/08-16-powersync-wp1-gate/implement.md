# WP1 integration and independent review implementation plan

## Allowed files

- .trellis/tasks/08-16-powersync-wp1-gate/research/evidence-index.md
- docs/architecture/SUPABASE_ACCEPTANCE_MATRIX.md
- docs/IMPLEMENTATION_STATUS.md

## Ordered steps

1. Assemble the evidence index from child artifacts and exact commits.
2. Run Coordinator checks, then one fresh independent Sol review.
3. Route verified findings back to their leaf, rerun review only after the consolidated set is resolved, and record the decision.

## Verification

- python3 ./.trellis/scripts/task.py validate 08-16-powersync-poc-refinement
- git diff --check
- git status --short

## Stop condition

Any missing real evidence, unresolved P0/P1, dirty unowned code, or matrix threshold failure produces Hard Stop.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
