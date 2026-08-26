# Attachment transport decision

## Goal

Evaluate the PowerSync Alpha attachment helper once against PasteBuddy requirements and freeze the fallback if any required case fails.

## Dependencies

powersync-appgroup-handoff and powersync-quota-settlement.

## Requirements

- Use a fixed evaluation set: reserve, upload, commit, retry, cancel, half-upload, relaunch, delete, quota, account switch, and exact-object isolation.
- Freeze `AttachmentTransport` as an injected protocol; hosted and fault tasks
  consume it without editing this owner.
- Record raw non-secret evidence and a binary helper Pass/Fail decision.
- On any required-case failure, choose Supabase signed URL plus local-only attachment queue; do not patch the helper.

## Acceptance criteria

- [ ] Every required case has a reproducible result bound to SDK version and source commit.
- [ ] Exactly one transport is selected for subsequent hosted tasks.
- [ ] The selected path leaves no orphan object after the tested cancel/delete/retry sequences.

## Out of scope

- No more than one helper evaluation cycle.
- No production Storage bucket or real user attachment.

## Blocking open questions

None. A failed execution prerequisite is a task failure or Hard Stop, not permission to broaden scope.
