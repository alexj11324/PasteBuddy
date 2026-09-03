# Lessons

## Image drag/paste
- OCR text is search metadata, not a paste representation. Advertising `public.utf8-plain-text` on an image `NSItemProvider` makes text fields (Cursor, Electron, NSTextView) take OCR instead of the image. Type identifier order does not win; the destination picks the type it prefers.
- `NSImage.writeObjects` / `tiffRepresentation` turns stored PNG into a huge uncompressed TIFF. Write stored PNG/TIFF bytes through. Convert only when the bytes are neither.
- Do not use `NSItemProvider(object: NSImage)` on the drag/copy path; it decodes eagerly and vends TIFF.
- PNG-only `registerDataRepresentation` is not enough for macOS drag. AppKit destinations want TIFF/`NSImage`; Finder, Electron, and chat composers want `registerFileRepresentation` (a real PNG file). Keep OCR text off, and register PNG + lazy TIFF + `NSImage` + file together. Set `suggestedName`.
- Do not build the `NSItemProvider` during SwiftUI `body`. Image cards re-render on thumbnail load and click-to-select; a captured provider from the previous body is replaced and the drop comes up empty. Create the provider inside the `.onDrag` closure.
- Unpinned Shelf/Side Panel hides on resign-active. Dragging a photo into another app deactivates PasteBuddy before the destination loads promised PNG/TIFF/file data. Keep the panel alive for the pointer session, drop `.transient` while that session is active, and delay hide until after mouse-up.
- X MCP was unavailable; Exa `site:x.com` returned no extra NSItemProvider drag hits. Apple docs: `registerFileRepresentation` load handler completion is `(url, coordinated, error)` — pass `coordinated=false` for a temp file we wrote.

## macOS 26 minimum
- SwiftPM: `.macOS("26.0")`. Info.plist / linker: `LSMinimumSystemVersion` and `-platform_version macos 26.0`.
- Raising the deployment target makes `#available(macOS 26.0, *)` unnecessary; unwrap it or the compiler warns and fallbacks become dead code.
- Official SPM docs expose `SupportedPlatform.MacOSVersion.v26` (PackageDescription 6.2+). String `"26.0"` works with tools 6.0.
- X MCP was unavailable; Exa `site:x.com` returned no extra deployment-target reports beyond Apple/SPM docs.

## Test builds on Desktop
- Desktop iCloud File Provider copies `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` onto `.xctest` bundles and ad-hoc `codesign` fails with “resource fork, Finder information, or similar detritus”. Use `~/Library/Developer/Xcode/DerivedData` as the SwiftPM scratch path.

## Secret-key 拦截修复（2026-09-02）
- `PrivacyConfiguration.blockLikelySensitiveText` 默认 true 会把 bare token（AKIA/ghp_/sk_live/bearer 等）经 `captureDecision → .sensitiveText` 静默丢弃，面板无任何反馈。改默认 false + `schemaVersion` 1→2 一次性迁移（`PasteBuddySnapshot.migrateIfNeeded`，`load`/`loadAsync` 双路径调用）。
- 脏分支上不要用 `git checkout -- <file>` 做"基线对照"，会连分支改动一起抹掉（本次靠预存 patch 恢复）。隔离对照应逐行 revert 或用 worktree；动 destructive git 操作前先 `git diff > /tmp/xxx.patch` 留底。
- 本地 `swift test` 默认 `.build` 的 Sentry/Iroh 二进制 artifact 可能损坏（XCFramework Info.plist 解码失败）；按 `script/ci.sh` 用隔离 scratch-path + `CLANG_MODULE_CACHE_PATH`/`SWIFT_MODULE_CACHE_PATH` 跑，和 CI 一致。
- `swift test` 输出用 grep 取失败行时注意管道退出码会被 `head/tail` 掩盖；写日志文件再 grep，并 `echo EXIT=$?` 取真实状态。
