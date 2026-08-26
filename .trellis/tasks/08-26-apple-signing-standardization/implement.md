# Apple 签名与本地 CI/CD 实施计划

## Preconditions

- 最新 `prd.md` 与 `design.md` 获得用户明确批准。
- 运行 `python3 ./.trellis/scripts/task.py start` 后再修改产品代码、workflow 或 GitHub 设置。
- 开始前记录 `git status --short`、当前 branch/HEAD、现有 GitHub workflows/protection/environments/runners JSON。
- 只处理本任务文件；保留并排除现有 PowerSync 与 local-AI Trellis 脏文件。

## Workstream A — Canonical local CI

1. 新增 `script/ci.sh`，组合本地化、Swift tests 和 iOS Simulator unsigned compile，缓存/DerivedData 全部放在 `/private/tmp` 或 runner temp。
2. 新增/更新正式 pipeline 测试，验证 CI 脚本包含所有强制 gate 且不启动/安装 App。
3. 本机运行 `script/ci.sh`，记录耗时与真实退出状态。
4. 提交为独立可回滚 concern。

## Workstream B — Deterministic development signing

1. 在 `script/build_and_run.sh` 固定 Team ID 和渠道合同。
2. 重写 identity resolution：显式 hash、唯一有效候选、多候选 fail closed；校验证书类型/Team/私钥。
3. 收紧 feature `--package` 与 stable Dev install 的行为边界；包名加入 source SHA。
4. 为 Developer ID 参数预留正确的 `--timestamp --options runtime`，但正式发布只由 release script 调用。
5. 扩展 `PasteBuddyAppRuntimeTests` 覆盖错误 Team、ad-hoc、多候选、branch install gate、nested-before-outer signing、release options。
6. 在临时隔离 checkout 验证 feature package；在集成交付阶段才运行稳定 Dev runtime。
7. 提交为独立可回滚 concern。

## Workstream C — macOS release and notarization

1. 先通过 GSM inventory 查询现有 Developer ID/notary/profile assets；不存在时按 `general-secrets-store` 规范创建，不把内容输出到日志。
2. 新增 `script/release_macos.sh`，实现 tag/main ancestry、clean source、Developer ID、nested signing、runtime/timestamp、notary wait、staple、spctl、checksum/provenance。
3. 增加正式 release-policy tests，失败路径使用 `/private/tmp` fixture/probe，不持久化一次性测试文件。
4. 新增 `.github/workflows/macos-release.yml`，绑定 release runner/environment/OIDC/GSM/GitHub Release。
5. 使用无 credential 的 dry-run/static gate 验证 workflow；有 credential 后执行真实公证 smoke，只有全部通过才创建 Release。
6. 提交为独立可回滚 concern。

## Workstream D — GitHub Actions CI and TestFlight hardening

1. 新增 `.github/workflows/ci.yml`，使用固定 self-hosted labels、最小权限和 concurrency。
2. 更新 `.github/workflows/testflight.yml`：self-hosted release labels、main SHA gate、environment、权限分离、cleanup。
3. 更新 `script/push_testflight.sh` 与 workflow 合同测试，保证本地与服务端都 fail closed。
4. 使用 actionlint（若仓库已有/可安全安装）或等价 YAML/workflow 解析，再运行本地合同测试。
5. 提交为独立可回滚 concern。

## Workstream E — Runner and repository setup

1. 新增/完成可审计 runner setup/uninstall 文档与脚本，registration token 只从 `gh api` 内存传递。
2. 经系统授权创建/使用专用普通 CI 用户并注册 `pastebuddy-ci` runner service。
3. 注册按需 `pastebuddy-release` runner；确认普通 CI job 无法匹配 release label。
4. Push 实施分支并创建/更新 PR；等待 `CI / verify` 在本地 runner 上真实成功。
5. 记录现有 GitHub protection/environment JSON，然后创建 `testflight`、`macos-production` environments 与 source rules。
6. 在 required check 已真实出现后配置 main branch protection。
7. 使用 GitHub API 回读 runners/protection/environments/workflows，证明设置已生效。

## Workstream F — Documentation and final acceptance

1. 重写 `docs/DEVELOPMENT_SIGNING.md` 为渠道矩阵和日常开发/稳定 Dev/正式 release 指南。
2. 更新 `docs/TESTFLIGHT_CI.md`，记录 self-hosted release runner、environment gate、OIDC 和故障恢复。
3. 新增 macOS release/runner runbook，包含证书轮换、runner update/offline、unregister、Keychain cleanup、notary failure 和 rollback。
4. 执行 secret scan，只报告路径/类型，不打印 credential 内容。
5. 按 AC1–AC11 做逐项 completion audit；证据不足的条目保持未完成。
6. 聚焦提交并 push/update PR；不自动 merge。

## Validation Commands

以下是计划命令，实施时根据最终脚本参数精确化：

```bash
script/ci.sh
swift test --filter PasteBuddyAppRuntimeTests
python3 script/localization_catalog_workflow.py check
xcodebuild -project PasteBuddyiOS.xcodeproj -scheme PasteBuddyiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/PasteBuddy-CI-DerivedData CODE_SIGNING_ALLOWED=NO build
PASTEBUDDY_CODESIGN_IDENTITY=<explicit-dev-hash> script/build_and_run.sh --package
script/build_and_run.sh --verify
codesign --verify --deep --strict --verbose=4 '/Applications/PasteBuddy Dev.app'
codesign -dvvv -r- '/Applications/PasteBuddy Dev.app'
gh api repos/alexj11324/PasteBuddy/actions/runners
gh api repos/alexj11324/PasteBuddy/branches/main/protection
gh api repos/alexj11324/PasteBuddy/environments
gh run list --workflow ci.yml --limit 10
```

真实 macOS release 验证还必须包含：

```bash
codesign --verify --deep --strict --verbose=4 <stapled-app>
spctl --assess --type execute --verbose=4 <stapled-app>
xcrun stapler validate <stapled-app>
shasum -a 256 <release-zip>
gh release view <tag> --json tagName,targetCommitish,assets,url
```

## Risky Files and Rollback Points

- `script/build_and_run.sh`: 直接影响稳定 Dev 签名/TCC；任何失败先回滚此 concern，不用 ad-hoc 绕过。
- `.github/workflows/testflight.yml`: 真实上传路径；先静态与 `--skip-push` 验证，避免重复 build。
- `.github/workflows/macos-release.yml`: 正式证书和 GitHub Release；只有 tag/source/notary 全部通过才允许 publish。
- GitHub branch protection/environment：必须先记录旧 JSON，确认 CI context 存在后再设置，避免锁死 main。
- runner service/macOS users：卸载 runner 不得删除 PasteBuddy 用户数据、默认 Keychain 或现有证书。

## External Inputs That May Gate Final Acceptance

- 有效的 Developer ID Application identity/private key。
- 匹配 production entitlements 的 Developer ID provisioning profile（若 CloudKit/keychain group 启用）。
- App Store Connect/notary API key 对 macOS notarization 的权限。
- 本机管理员授权以创建专用 runner 用户和安装 launchd service。

缺少这些输入不阻止先完成脚本、workflow、测试和普通 CI runner，但不得把 macOS CD 标记为已完成。
