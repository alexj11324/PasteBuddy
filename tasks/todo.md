# Secret Key 不上榜修复

- [x] 复现确认：默认 `PrivacyConfiguration` 下 bare token 经 `captureDecision` 被判 `.sensitiveText`（根因）
- [x] 回归测试先行（红）：默认允许 bare secret-key tokens；显式开启仍拦截；v1 快照迁移
- [x] 修复：`blockLikelySensitiveText` 默认改为 `false`（init + decoder fallback）
- [x] 迁移：`schemaVersion` 1 → 2，老快照载入时一次性把旧默认值翻成 `false`（设置里可重新打开）
- [x] 存量测试更新：`testPrivacySettingsPersistThroughEncryptedStore`、`testPrivacyPostureReportCovers…`、`testSharedContentImportPinsSharedTextAndBlocksSensitiveText`
- [x] 跑 `swift test`：9 个相关测试全绿；`script/ci.sh` 已跑 `swift test`，新测试即 CI 防回归，无需新 workflow
- [x] 收尾：code-reviewer 审过（REQUEST CHANGES → 已处理：迁移注释写明权衡 + 补 repository 回写测试）；更新 `tasks/lessons.md`

## Review
- code-reviewer 结论：双载入路径持久化正确、幂等、无并发问题；HIGH（显式 opt-in 被静默翻转）以注释写明产品决策 + 本总结告知处理；MEDIUM（缺 repository 回写测试）已补 `testRepositoryLoadMigratesV1SensitiveBlockingAndWritesBack` 并通过。
- 全量套件剩余 7 个失败用例与本次改动无关：3 个 CoreTests（repository 窗口计数）在改回旧默认值对照下原样失败；4 个 AppTests（shelf/side-panel）不引用隐私配置。系分支 `codex/integrated-delivery` 既有重构未完成所致。

## Review
（待填）
