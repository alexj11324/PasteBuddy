# Space Preview and Card Latency Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Space preview for selected cards and fail immediately when card-switch latency exceeds 100 ms.

**Architecture:** Reuse the existing SwiftUI preview state and key handlers. Add one explicit focus callback from card selection to the panel controller, then extend the existing Python monitor rather than creating a second measurement implementation.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XCTest, Python 3 standard library, macOS unified logging.

---

### Task 1: Card selection keyboard focus

**Files:**
- Modify: `Tests/PasteBuddyAppTests/PasteBuddyAppRuntimeTests.swift`
- Modify: `Sources/PasteBuddy/App/ClipboardShelfPanelController.swift`
- Modify: `Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift`
- Modify: `Sources/PasteBuddy/Views/ClipboardSidePanelView.swift`

- [ ] Add a failing contract test requiring card selection to set the list FocusState, yield one MainActor turn, and request panel key focus while panel presentation itself remains nonactivating.
- [ ] Run the focused test and confirm the expected failure.
- [ ] Pass a minimal focus callback from the controller into both panel views and invoke it from card selection.
- [ ] Run the focused test and existing click/double-click/drag tests.

### Task 2: Fail-fast latency gate

**Files:**
- Modify: `script/monitor_card_switch_latency.py`
- Create: `script/test_card_switch_latency.sh`
- Modify: `AGENTS.md`
- Test: `/private/tmp/test_pastebuddy_card_switch_monitor.py`

- [ ] Add failing parser/gate tests for a 100 ms threshold, immediate failure, and exactly 10 completed samples.
- [ ] Run the temporary test and confirm the expected failure.
- [ ] Add `--max-total-ms` and `--sample-count` using only the Python standard library; add `script/test_card_switch_latency.sh` that fixes them to `100` and `10`.
- [ ] Document `script/test_card_switch_latency.sh` and its expected exit 0/1 contract in `AGENTS.md`.
- [ ] Run the script self-test and temporary tests.

### Task 3: Runtime verification and commit

- [ ] Run full `swift test`.
- [ ] Run `script/build_and_run.sh --verify`.
- [ ] Open the Shelf through `script/open_dev_panel.sh shelf`, verify Space opens/closes preview with Computer Use and real window geometry, then repeat in Side Panel through `script/open_dev_panel.sh side`.
- [ ] Collect exactly 10 real switches with `script/test_card_switch_latency.sh`; confirm immediate exit 1 above 100 ms or exit 0 after all 10 pass.
- [ ] In Side Panel mode, verify double-click direct paste against a real external target, confirm `sidePanelDoubleClickCallback` diagnostics, exercise drag, and confirm card order is unchanged.
- [ ] Commit the preview feature after baseline commit `42e0d8b`.
