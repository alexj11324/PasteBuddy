# Space Preview and Card Latency Gate Design

## Goal

Make Space open and close the selected card preview without regressing immediate selection, double-click paste, or drag behavior. Turn the existing latency monitor into a fail-fast regression gate.

## Design

- Keep the panel nonactivating when shown so the external paste target remains recorded.
- After an explicit card selection, set the Shelf/Side Panel list FocusState, yield one MainActor turn, then request key focus for the existing panel. Existing SwiftUI `onKeyPress` and `previewedID` logic then handles Space; no global Space interception is added.
- Keep using `FrontmostApplicationTracker` for direct-paste targeting and verify double-click against a real target after the focus change.
- Extend `monitor_card_switch_latency.py` with threshold/sample arguments and add `script/test_card_switch_latency.sh` as the fixed gate: 10 completed switches, 100 ms maximum. The process exits immediately with status 1 when any switch exceeds 100 ms and exits 0 after 10 passing samples.
- Record the required post-change command in `AGENTS.md`.

## Verification

- TDD contract tests for card-selection focus handoff and fail-fast threshold behavior.
- Full `swift test`.
- Stable-signed `/Applications/PasteBuddy Dev.app` runtime verification.
- Computer Use: click a card, press Space to open, press Space to close.
- Computer Use plus diagnostics: double-click pastes into a real external target, drag remains available, and card order is unchanged.
- Real latency samples remain at or below 100 ms.
