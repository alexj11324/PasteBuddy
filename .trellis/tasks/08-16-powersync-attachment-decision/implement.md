# Attachment transport decision implementation plan

## Allowed files

- Sources/PasteBuddyPowerSyncPoC/AttachmentTransport.swift
- Sources/PasteBuddyPowerSyncPoC/AttachmentTransportProbe.swift
- Tests/PasteBuddyPowerSyncPoCTests/AttachmentTransportTests.swift
- .trellis/tasks/08-16-powersync-attachment-decision/research/decision.md

## Ordered steps

1. Freeze the evaluation matrix before running the helper.
2. Run each case once with redacted evidence.
3. Write the binary decision; implement only the minimal adapter for the selected path.

## Verification

- swift test --filter AttachmentTransportTests
- test -f .trellis/tasks/08-16-powersync-attachment-decision/research/decision.md
- git diff --check

## Stop condition

A helper failure immediately selects fallback; a fallback inability to meet exact-object and cleanup rules stops WP1.

## Handoff evidence

- Changed file list and exact diff summary.
- Every command with exit code and original failure output.
- Residual risks, exact source commit, and suggested focused commit subject.
