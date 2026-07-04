# 全 App 性能 / 交互响应 / 状态生命周期 / 一致性排查（分支 claude/great-euler-fe762f）

## 排查结论（按影响排序）

### P0-1 保存管线阻塞主线程（性能，最大头）
`PasteBuddyStore.scheduleSave` / `flushPendingSave` 在 MainActor 上同步执行
`snapshotForDiskPersistence`：对**每个** item 调 `refreshSearchDocument()`（HTML 正则
剥离 + 全文 folding + 双 SHA256），并对所有内存中 rtf/image 数据做 SHA256。
每次捕获 / 改名 / 贴标签 / 删除都触发 save()。截图多的会话每次保存主线程卡几十至几百毫秒。

修复：
- `snapshotForDiskPersistence` 改为 `nonisolated static`，只处理仍带 inline
  rtf/image 数据的 item（O(1) guard 跳过已外部化项）
- `scheduleSave` / `flushPendingSave` 中经 `Task.detached(priority: .utility)` 后台计算
- `saveImmediately`（无防抖的同步路径，测试用）保持同步语义

### P0-2 SourceApplicationIconResolver 负查询不缓存（性能，渲染热路径）
来源 app 未安装（如 iOS 同步项 / 已卸载 app）时，每张卡片每次渲染都会：
扫 runningApplications + LaunchServices 查询 + 8 个目录 fileExists（主线程磁盘 I/O）。
`NativeSourceAppSuggestionRow` / `SourceApplicationIconImage` 走 `icon(forApplicationName:)`
完全绕过缓存，每次敲键全量查。

修复：
- 未命中也写入缓存（sentinel），`didLaunchApplicationNotification` 时清空负缓存
- 按名称查询也加缓存入口，供建议行 / 图标视图复用
- `applicationSearchDirectories()` 缓存为 static

### P1-3 ClipboardMonitor 微优化（能耗 + 每次捕获的主线程 SHA）
- 轮询 Timer 无 tolerance → 加 0.15s，降功耗
- 捕获完成后 `lastFingerprint = Self.fingerprint(for: item)`（全文 + 全图 SHA256，
  在 MainActor.run 内）与 cheapFingerprint 格式永不匹配，纯浪费 → 删除。
  不改变去重语义（store 层 dedupe 不受影响）

### P2-4 面板 show/toggle 交互死区与重复重建（交互响应 + 一致性）
- `show()` 在面板已可见时仍走完整路径：重置搜索/过滤/选中 + 换 presentationID
  → 整棵 SwiftUI 树销毁重建。Cmd+Shift+B 重复按 = 无谓重置用户状态。
  修复：已可见且非退场动画时仅重新定位 + makeKey
- `toggle()` 在 120ms 退场动画期间按下 → hide() 静默 return → 快捷键无响应死区。
  修复：退场动画中 toggle 改为重新 show()（generation 机制已保证旧动画回调作废）

## 生命周期扫描结果（无需改动）
- observer / NSEvent monitor 注册-移除配对完整（上个 commit 已修 panel 泄漏）
- `PasteBuddyPanelHotKeyController.shortcutRecordingObserver` 无清理但对象为
  app 生命周期，无实际泄漏；不为洁癖引入 deinit assumeIsolated 风险
- `contentRevision` 求和方案理论有碰撞，但 itemIDs 变化必走 reloadData，实际不可达

## Todo
- [x] 排查：App/Controller/Store/Monitor/Views/Cache/Resolver 全量精读
- [x] P0-1 保存管线后台化
- [x] P0-2 图标解析负缓存
- [x] P1-3 Monitor tolerance + 删除死指纹写入
- [x] P2-4 show/toggle 修复
- [x] swift build + swift test 全量验证
- [x] Review 段落总结

## Review
- 最终 diff：4 个源文件 +112/-43（Store / Monitor / PanelController / ShelfPanelView），
  全部为行为保持的性能重构 + 2 个交互微修复，无 API 变化
- 验证：swift build 零警告；swift test 307 过 0 挂（2 跳过为原有跳过项）
- 语义等价性论证：
  - 保存管线：`snapshotToSave` 在调度时按值捕获，外部化延迟到防抖后基于同一值计算，
    结果一致；per-item guard 可跳过是因为"字段修改必伴随 refreshSearchDocument"
    的不变式由所有上游写路径维护（rename/setLabels/updateOCR/addCaptured/load 均已核对）
  - 外部化 dedupeHash 一致性：binaryHash(data:) = SHA256(data)，
    binaryHash(assetID:) = assetID = sha256Hex(data)，两者字符串相同，
    持久化前后去重身份不漂移（外部化是幂等的哈希保持变换）
  - 图标负缓存：didLaunchApplicationNotification 全清缓存，保证"后启动的 app
    图标可见"与原行为一致；唯一放宽是"安装但从不启动的 app"在缓存驱逐前显示
    generic 图标（原每帧磁盘探测换来的边缘能力，权衡明确）
  - Monitor 死指纹：cheapFingerprint 含 changeCount（每次必变）且与全量
    fingerprint 格式不同，两者数学上永不相等 → 删除写入不改变任何捕获/去重行为
- 未修但已记录：contentRevision 求和的理论碰撞（实际不可达）、
  hotKeyController 观察者无 deinit（app 生命周期对象）、
  面板每次打开的 presentationID 全量重建（近期 commit 的有意设计，不动）
- 待人工验证（真机）：连按 Cmd+Shift+V 快速开关面板无死区；面板开着时按
  Cmd+Shift+B 不再丢失搜索词；大量截图入历史后连续捕获无卡顿
