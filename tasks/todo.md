# Fix image drag-to-paste after PNG-only provider

## Background
- After `06654f8`, dragging an image from Shelf/Side Panel no longer pastes.
- Last change removed OCR `public.utf8-plain-text` (correct) and replaced `NSItemProvider(object: NSImage)` with PNG-only `registerDataRepresentation`.
- Many destinations reject PNG-only providers: AppKit wants TIFF/NSImage; Finder, Electron, and chat composers want a file.

## Plan
- [x] Red: image provider must load NSImage, TIFF, and a PNG file; still omit OCR text (inline + hydrated)
- [x] Green: register TIFF + NSImage + `registerFileRepresentation` without utf8-plain-text
- [x] Tests green (`testImageItemProviderPublishesPNGWithoutOCRPlainText`, `testHydratedImageItemProviderPublishesDroppableImageWithoutOCRPlainText`, `testImageCardDragProviderPublishesImageWithoutOCRPlainText`)
- [ ] Official `script/build_and_run.sh --verify` and runtime drag check
- [x] Update `tasks/lessons.md`

## Review
- Pending final review before handoff.

---

# 性能优化 + 功能缺陷修复（分支 optimize/perf-and-defects）

## 背景
- WIP 已全部 stage 并带入新分支：移除"手动新建文本条目"全链路、MCP 默认工具收窄、Iroh 配对 URL、MCP 客户端指南扩展
- 基线：swift test 310 过 0 挂 2 跳过（6.2s）

## 计划
- [x] stage 全部改动
- [x] 新开分支 optimize/perf-and-defects
- [x] swift test 基线全绿（310/0/2）
- [x] 精读热路径：ClipboardMonitor → PasteBuddyStore → 搜索/过滤 → 持久化
- [x] 定位可量化的性能问题与功能缺陷（5 项，见 Review）
- [x] 每项修复配测试（Monitor 红→绿 2 个 + Store 锁定 2 个 + 源码合同更新）
- [x] swift build 0 warning + swift test 314 过 0 挂 2 跳过
- [x] Review 章节

## Review

### 修复清单（工作树未 stage 部分，与 staged 的 WIP 分层隔离）
1. **缺陷·URL 捕获被网络阻塞 + 丢条目**（ClipboardMonitor.swift）
   - 旧：捕获路径同步 `await` LPMetadataProvider（默认 30s 超时）后才入库；期间新复制会 cancel 前一条 → URL 条目永久丢失，且复制 URL 后面板迟迟不显示。
   - 新：入库零网络依赖，落库后异步触发 Store 已有的幂等 `enrichLinkPreviewMetadataIfNeeded`（带 in-flight 去重）。丢失窗口 30s → 本地转码毫秒级。
2. **缺陷·纯文本 URL 被错判为 .mixed**（ClipboardMonitor.swift）
   - 旧 URL 提升分支条件 `text == nil` 数学上恒假（死分支）；终端/编辑器复制的纯 URL 文本判成 .mixed，无 urlString、不能 enrich 预览。
   - 新：text 整体是合法 web URL 且无其他 URL 来源时提升为 .url。
3. **性能·防抖保存在调度时做全量重活**（PasteBuddyStore.swift）
   - 旧：每次 save() 调度（每次捕获/OCR/pin）都在主线程同步跑 `snapshotForDiskPersistence` — 全量 items refreshSearchDocument + 对内存图片/RTF 全量 SHA256；350ms 防抖窗口内被取消的调度全是白算。
   - 新：外部化移到防抖窗口之后、`Task.detached(.utility)` 后台执行；被取消的 save 零成本。`externalizedPayload`/`sha256Hex` 标记 nonisolated。
4. **性能·搜索每 item 重复 normalize 同一 query**（ClipboardModels + Store）
   - 新增 `matchesNormalizedSearchQuery` 快路径；`filtered`/`makeFilteredItemCount` 循环外 normalize 一次。maxHistoryItems 上限 10,000 时每键省 1 万次 folding。
5. **性能·每次捕获跑 2 遍 smart pinboard 全量分类 + 无效 dedupe 全量重建**（PasteBuddyStore.swift）
   - addCapturedItem 删除冗余 `refreshExistingSmartPinboards()`（pruneHistory 内部刚跑过）；pruneHistory 仅在实际移除条目时 `rebuildDedupeIndex()`（增量索引维护重新生效）；OCR/enrich 三处 rebuild 删除（`deduplicationHash` 输入不含 ocrText/title/预览图，证：markOCRFailed 原本就无 rebuild）。约束注释落在 deduplicationHash 源头。
   - 死代码清理：lastFingerprint 双格式混写导致的恒真守卫、cheapFingerprint、同步版 makeItem 的 90 行重复逻辑（复用 snapshot 版，PasteboardWriterTests 30 个合同测试守护）。

### 验证
- swift build：0 error 0 warning（touch 强制重编译验证）
- swift test：**314 过 0 挂 2 跳过**（基线 310 + 新增 4：ClipboardMonitorTests 2 个（TEST-NET 红→绿）+ Store 外部化落盘锁定 + 变音符搜索锁定）
- 源码合同测试 testShelfLinkCardsUsePersistedMetadataPreviewWithoutViewFetch 更新为新架构合同（Monitor 禁止 `await ClipboardLinkMetadataFetcher.fetch` + Store 持有 metadata 应用逻辑）
- 净 diff：+151/−212（修 5 类问题同时净删 61 行）

### 第二轮：Iroh 同步 metadata 回归修复（自查发现，用户确认后修复）
- **回归成因**：Iroh 发送挂在 `onItemCaptured`（捕获时刻），修复 1 让捕获不再等 enrich → 对端只收到裸 URL；且对端接收走 `addCapturedItem`，dedupe 命中只 bump 不合并 → 补发也会被吞。
- **修复三件套**：
  1. Store 新增 `onLinkPreviewMetadataEnriched` 回调，enrich 落库后广播升级版 item
  2. `addCapturedItem` dedupe 命中时 `adoptRicherLinkPreviewMetadata`——只升级不降级（裸版重复复制永不清掉已有缩略图）；合并字段均不参与 deduplicationHash，索引无需 rebuild
  3. App 层挂接：enriched 广播 → `irohSync.sendIfConnected`（iOS 无 LP 能力，Mac 代取回推；环终止：对端已富则合并被 guard 挡下，无循环）
- **测试**：+4（enrich 广播（注入 `fetchOverrideForTesting` 测试缝）、dedupe 升级合并、防降级、App 挂接合同）→ **318 过 0 挂 2 跳过**

### 第三轮：蓝军尾项全部收口
- **BUG-1 retention 续命**：`pruneHistory` 从只看 `createdAt` 改成看 `max(createdAt, updatedAt)`；刚重新复制过的旧条目不再被 30 天裁剪误删。
- **BUG-2 sync 隐私门**：新增 `addSyncedItem`，Iroh 接收统一走本地 `captureDecision(includePause: true)`；`captureText = false`、排除应用、暂停捕获、敏感文本规则都会生效。
- **BUG-3 慢捕获串行化**：`ClipboardMonitor` 去掉“后来一条 cancel 前一条”的语义，改为 `previousTask` 串行等待，只在 stop 场景响应 cancel；4K 截图/慢转码不再丢第一条。
- **BUG-4 title-only 补全不外发**：link preview enrich 只有拿到 image 时才触发 `onLinkPreviewMetadataEnriched`，title-only 升级只留本地，避免对端 dedupe 吞包后两端状态不一致。
- **BUG-5 超大帧降级重试**：`IrohClipboardSyncService.send` 遇到 `frameTooLarge` 会剥离 image/RTF 后重试一次，且不把连接状态误标成 `.failed`。
- **AUDIT-1 搜索语义对齐**：内存和 SQLite 统一到同一规则：字母数字按 normalized token-prefix，纯符号/emoji fallback 到 normalized contains；flush 前后 query 结果一致。
- **AUDIT-2 侧栏计数语义确认**：`ClipboardSidePanelView` 继续使用 `sideItemTotalCount = store.filteredItemCount(for: sideScope)`，列表仍取分页 `filteredItems(for:)`；“共 N 条 / 当前页最多 100 条”语义保持明确，不需要额外 UI 改动。

### 最终验证
- `swift build`：通过
- `swift test`：**327 过 0 挂 2 跳过**
- `git diff --check`：通过

### 已知未动项（有意保留）
- MCP `migratedEnabledTools`：用户手动全开 10 个工具会被一次性迁移降为 4 个默认 —— 概率极低的产品迁移决策，未改
- `NewPinboardNamePrompt.runModal` 阻塞式 NSAlert：staged WIP 的设计选择，行为可接受
- 性能收益为复杂度级推导（O(n)×每调度 → O(n)×每落盘等），未做微基准计时
- 上一轮遗留：真机验证侧边栏预览跟随（tasks/archive-2026-06-preview-fix.md）
