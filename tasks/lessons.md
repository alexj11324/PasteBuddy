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
- 本地 `swift test` 默认 `.build` 的 Sentry 二进制 artifact 可能损坏（XCFramework Info.plist 解码失败）；按 `script/ci.sh` 用隔离 scratch-path + `CLANG_MODULE_CACHE_PATH`/`SWIFT_MODULE_CACHE_PATH` 跑，和 CI 一致。
- `swift test` 输出用 grep 取失败行时注意管道退出码会被 `head/tail` 掩盖；写日志文件再 grep，并 `echo EXIT=$?` 取真实状态。

## PR #35 经验（2026-09-03）
- 测试里的假 secret 字面量（sk_live_…/ghp_…）会被 GitGuardian 当真 key 拦下。fixture 用运行时拼接（"sk_live_" + String(repeating:)），别留完整字面量。
- 若假 secret 已进历史 commit，rescan 不会过（按 commit 扫）：squash 重写历史 + force-push 才能变绿。个人分支可接受，公共分支先问人。
- Codex review 在 force-push 后可能卡 Running（旧 sha 的 review 不会自己结束）；等两轮还不动、且无 required review、无 findings，就按既定标准 merge，不要无限等。

## 双击粘贴回归（2026-09-03，93889dd 引入，随 cc0c175 显性化）
- `ClipboardSidePanelView`/`ClipboardShelfPanelView` 的 `refreshSideItems`/`refreshShelfItems` 绑定在 `.onChange(of: queryState)`，而 `queryState` 里带 `store.dataRevision`；`PasteBuddyStore.snapshot` 的 `didSet` 无条件 bump 它，几乎任何写入（拷贝入库、异步 hydrate、密钥分类）都会触发。刷新函数如果在 `await` 之前同步清空已渲染的 items（`paging.beginLoading` + `replaceItems([])`），就会在 dataRevision 抖动的瞬间把 SwiftUI 行视图连同手势识别状态一起销毁重建——如果这瞬间恰好落在双击的两次点击之间，`.onTapGesture(count: 2)` 永远等不到"同一视图上的第二次点击"，双击直接失效。修法：改成 stale-while-revalidate，旧数据留在屏幕上直到新数据 ready 再一次性原子替换，不要先清空。
- 这类"清空再异步回填"模式对 dataRevision/queryRevision 这种高频抖动的字段特别危险；凡是 `.onChange` 绑定到一个会被"几乎任何写入"触发的 revision 计数器上时，刷新逻辑默认应该是增量/原子替换，而不是 clear-then-refill。
- 本仓库对这类 SwiftUI 手势时序 bug 完全没有行为测试覆盖，只有对源码文本做 `source.contains(...)` 顺序断言的"契约测试"（如 `testShelfSingleClickSelectionIsImmediateAndOnlyDoubleClickPastes`）——这类测试测不出运行时状态机问题，只能防止"代码被改成明显不同的写法"，不要误以为它们等价于回归测试。真正能测状态机的是像 `ClipboardPanelPagingState` 这样的纯 struct，优先把类似逻辑抽成可单测的纯状态，而不是只在 View 私有方法里用字符串断言兜底。

## 分支上既有的 7 个失败测试（2026-09-03，随双击修复一并处理）
在干净的 `cc0c175` HEAD 上单独跑就已经失败，和这轮改动无关——本地 CI 手动触发这道闸没人按，才在分支上躺了这么久没人发现，直接证明"CI 加固"那部分的必要性。修法分两类：
- **生产代码真 bug**：`PasteBuddyStore.makeMainListItems()` 的 `.history`/`.pinboard` 分支误用了 `defaultHistoryPageLimit`（100）去查 `mainListItemsSnapshot`，导致它和 `filteredItems`（本该是小窗口）一样被窗口化。`mainListItemsSnapshot` 是 `setSelectedItemIDs`/`selectedItemsInDisplayOrder` 等选择解析要用的"稳定全量视图"，被窗口化后窗口外的条目选不中。改成 `maxHistoryCacheLimit`（2000）。教训：一旦某个 accessor 的契约是"要看到全量"，绝不能偷懒复用"只看当前小窗口"的那份查询逻辑，哪怕两处代码长得很像。
- **测试真过期，生产代码是对的**：`load()`/`loadAsync()` 命中已有仓库快照时，`snapshot.items` 本来就该是有界缓存（`initialHistoryCacheLimit`=80，这是 cc0c175 引入的设计），`testCaptureAndSyncRetainItem501AcrossSaveAndRelaunch` 还在断言重启后 `snapshot.items.count==501`，是没跟着一起改的旧契约；`enrichLinkPreviewMetadataIfNeeded` 早改成走 `item(withID:)` + `currentItem.payload.xxx` 而不是 `snapshot.items[index]` 直接下标，两个 `ShelfCollectionChipsAcceptDraggedClipboardItems` 测试还在断言 `store.snapshot.items.first(where:).map(category.matches)` 这种旧写法；`ClipboardPanelFiltersMenu` 从写这个文件的第一个 commit 起就是纯 `Menu`+`Label`，测试里 `chrome: .toolbar`/`ShelfToolbarCircleIcon`/`.frame(width: 42, height: 38)` 从来没在生产代码里存在过——像是照着另一个组件抄断言时抄错了目标，从 e5171b5（7 月）起就没人发现。教训：这类 source-pattern 契约测试一旦断言的目标字符串是"应该长什么样"而不是"现在长什么样"，特别容易在没人跑 CI 的窗口期里悄悄和现实脱钩；改动一个 View/Store 方法的落地写法后，`grep` 一下测试文件里有没有引用旧写法，比事后靠 CI 抓更快。
- 顺手发现但没深挖：`testCaptureAndSyncRetainItem501AcrossSaveAndRelaunch` 里对 `reloaded.mainListItemsSnapshot`（走 `databaseFilteredItems`）算总数时曾观察到 500 而不是 501（`repository.itemCount()` 本身是对的，501）。没有专门时间查是 `ClipboardItemPageRequest`/`fetchPage` 哪一步在大批量、同一时刻 `createdAt` 的场景下漏了一条，测试里只保留了"item 仍可达"的断言，没有断言总数。值得单独起一轮查。

## 设置界面的可用性问题（2026-09-03，重构后跑起来才发现）
- **`ByteCountFormatter` 的 `.file` 按十进制算**。用二进制常量（`512 * 1_024 * 1_024`）定义预设、再交给它格式化，用户看到的就是 536.9 MB / 1.07 GB / 107.37 GB 这种谁也不会主动选的数字。凡是「预设值 → 格式化后展示」的链路，预设必须按格式化器的进制来定义，否则每一档都是小数。
- **`DisclosureGroup` 在 Form 里的命中区只有 chevron 和 label**，行的其余部分点不动。把低频项藏进折叠区看着很整洁，实际是把它们藏在了一个大部分面积对指针无效的控件后面。macOS 设置页里宁可多列几行，也不要用它做「高级」分组。
- **不要在 Form 的 Section 里放 `.listStyle(.bordered)` + 固定高度的 List**：Section 自己画一个框，List 再画一个框，页面滚动条里又嵌一个滚动条，底部还会切掉半行。列表型设置项直接用普通 Form 行 + 每行自带删除按钮 + 末尾一个「添加…」行，一个框一个滚动条，也不用维护 selection 状态和 disabled 的减号按钮。
- **`TextField` 在 Form 里默认没有边框**，看起来就是一个飘在那儿的数字，用户不知道能输入。数值输入要显式 `.textFieldStyle(.roundedBorder)`。
- **`FileManager.displayName(atPath:)` 会带 `.app` 后缀**（当 Finder 开了「显示所有文件扩展名」时）。取 App 显示名走 bundle 的 `CFBundleDisplayName` / `CFBundleName`，兜底用 `deletingPathExtension().lastPathComponent`——项目里 `InstalledApplicationCatalog` 已经有这套逻辑，别再写一遍。
- **`NSWorkspace.urlForApplication(withBundleIdentifier:)` 能解析出扫描目录之外的 App**（钥匙串访问在 `/System/Library/CoreServices`）。只扫 `/Applications` 的目录枚举会让这些条目退化成「裸 bundle id + 空图标」。
- **一次性迁移要写成分步的**（`if schemaVersion < 2 { … }` / `if schemaVersion < 3 { … }`），不要写成「只要低于当前版本就全做一遍」。后者在加第 3 步时会让已经在 v2 的快照重跑一次 v2 的重置，把用户改过的设置又推回默认。
- **合成事件驱动 macOS app 做验证时**：滚轮事件对 SwiftUI Form 常常不生效，改用 AX 的 `AXVerticalScrollBar` 设 `AXValue`；点击必须先 `CGEventMouseMoved` 到目标位置，且 app 必须是 frontmost，否则点击只会激活窗口而不落到控件上——我一度因此误判「侧栏选择会自己弹回」，实际是后台窗口吞掉了第一次点击。截图用 `screencapture -l<windowid>` 只抓目标窗口，不要抓全屏（会把用户的其他窗口内容一并读进来）。
