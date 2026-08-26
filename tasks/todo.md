# Fix intermittent image drag from Shelf / Side Panel

## Background
- Dragging photos from Shelf/Side Panel sometimes fails to drop.
- Image cards rebuild `NSItemProvider` during SwiftUI `body` (thumbnail/selection refresh).
- Unpinned panel hides on resign-active while the destination still needs promised PNG/TIFF/file data.

## Plan
- [x] Red: provider is created inside `onDrag`; unpinned panel must not dismiss during an active pointer/drag session
- [x] Green: keep panel alive until mouse-up; drop `.transient` while the pointer session is active
- [x] Tests green (isolated worktree; main tree had concurrent unrelated edits)
- [ ] Official `script/build_and_run.sh --verify` and runtime drag check (cannot overwrite PasteBuddy Dev.app from a dirty/isolated tree)
