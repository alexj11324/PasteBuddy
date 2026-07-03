# 修复侧边栏 preview + 方向键联动（分支 codex/fix-preview-bottom-scroll）

## 症状
1. 预览开启、列表滚到视口底部附近按 ↑/↓ → 预览消失，无法持续
2. 列表 items 不跟随选中滚动
3. ↑/↓ 完全失灵（codex 改动引入的回归）
4. 预览与面板窗口重叠（codex 改动引入的回归）

## 根因
- codex 未提交改动把文本预览换成 NSTextView 并劫持裸 ↑/↓ 为"滚动预览文本"，仅 ⌥/⌘+方向键才移动选中，且每次 update 抢 first responder → #3
- "延迟选中"异步状态机（scrollTarget + RunLoop 双跳 + 2 次重试）失败后卡死，选中永不落地，正常 scroll-into-view 被 `scrollsPrimary` 抑制 → #1 #2
- popover 异步 re-show 风暴 + positioningRect 可设到可视区外 → #1 #4

## 计划
- [x] 取证：diff、interaction model、panel controller、shelf 调用点
- [x] 备份 codex 改动到 scratchpad/codex-attempt-backup.diff
- [x] revert Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift 到 HEAD（恢复原键盘语义 + SwiftUI 文本预览）
- [x] ClipboardSidePanelView.swift：删除延迟选中状态机，选中即时落地；保留 coordinator popover 接线
- [x] ShelfCollectionRepresentable.swift：删除 scrollTarget 机器；applySelection 恢复无条件 scroll-into-view；popover 同步锚定 + 锚点 rect 钳制到可视区；滚动时 reanchor
- [x] 更新 PasteBuddyAppRuntimeTests：删除状态机断言，改为固化新不变量
- [x] swift build && swift test 全绿
- [x] Review 章节

## 第二轮（真机反馈：列表不跟随 + 预览钉在底部重叠）
- 根因：`NSCollectionView.scrollToItems(.nearest*Edge)` 在本项目配置下从未生效过 —— 证据三角：HEAD 用它（用户原始投诉 #2）、codex 换居中+重试机（仍坏）、我恢复 HEAD（复现）。重叠是下游症状：选中走出视口后锚点钳制把 popover 钉在视口底缘。
- 修复：绕开 scrollToItems，新增 ShelfCollectionScrollMath 纯几何函数直接算 clip origin，`clipView.scroll(to:)` 同步滚动；加 previousPrimarySelectedID 门控（滚动真正生效后必须门控，否则每次数据刷新都会把视口拽回选中行）；退化锚点从 1pt 细线改为贴边整行 rect。
- 验证：swift build 通过；297 测试 0 失败（含 8 个 ScrollMath 真单元测试：上/下/部分可见/钳制/横向）。

## Review
- 最终 diff：3 文件 +163/-24（codex 原稿为 4 文件 +578/-88），ClipboardShelfPanelView.swift 完整回退到 HEAD
- 保留 codex 唯一正确的架构决策：popover 由 Coordinator 持有、锚定在不会被回收的 clipView 上（解决 row 复用杀 popover 的原始根因）
- 新增不变量：预览锚点 rect 永远钳制在可视区内（previewAnchorRect），行滚出屏幕时 popover 钉在视口边缘不消失
- 验证：swift build 通过；swift test 289 过 0 挂；4 个相关测试逐一确认通过；Sources 无状态机残留引用（grep = 0）
- 待人工验证：真机打开侧边栏，开预览后按住 ↓ 连续导航到列表底部，确认预览持续跟随、列表滚动、无重叠
- codex 原稿备份：scratchpad/codex-attempt-backup.diff（会话结束后清理）
