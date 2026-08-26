# Apple 签名与本地 CI/CD 技术设计

## 1. Architecture Overview

签名与交付拆成四条互不混淆的路径：

1. **Feature build**：任意已提交分支在本机或普通 self-hosted CI runner 上 build/test；需要签名产物时使用 Apple Development，但不安装、不启动、不访问稳定数据。
2. **Stable Dev promotion**：只有干净的 `codex/integrated-delivery` 可覆盖 `/Applications/PasteBuddy Dev.app`，随后运行真实 TCC/runtime 验收。
3. **iOS TestFlight CD**：只有 `main` 的确定 SHA 可进入受保护 TestFlight environment；本地 release runner archive/export/upload。
4. **macOS Developer ID CD**：只有 `v*` tag 的确定 SHA 可进入受保护 macOS production environment；本地 release runner 完成签名、公证、staple、checksum 和 GitHub Release。

GitHub Actions 是控制面，负责触发、required checks、environment gate、OIDC、审计和 Release；本地 Apple Silicon Mac 是执行面，不使用 GitHub-hosted macOS minutes。

## 2. Trust Boundaries

### 2.1 Ordinary CI runner

- Label：`self-hosted`, `macOS`, `ARM64`, `pastebuddy-ci`, `xcode-27`。
- 运行在专用标准 macOS 用户与独立 work 目录。
- 无 Developer ID、ASC、notary 或生产数据权限；workflow 仅 `contents: read`。
- 只执行 `pull_request`/`main` 的测试、无签名 simulator build 和静态签名策略测试。
- 不启动 PasteBuddy，不覆盖 `/Applications/PasteBuddy Dev.app`，不调用发布脚本。

### 2.2 Release runner

- Label：`self-hosted`, `macOS`, `ARM64`, `pastebuddy-release`, `xcode-27`。
- 与普通 CI runner 分开注册和使用独立 work 目录；默认离线，需要发布时才启动。
- 只有引用 `testflight` 或 `macos-production` environment 的 job 才能运行发布步骤。
- GitHub OIDC 取得 GCP 短期身份；credential 从 `general-secrets-store` 写入 runner 临时目录或一次性 Keychain，cleanup trap 始终删除。
- 不复用开发者日常默认 Keychain 作为 CI 正式签名源。

单台物理 Mac 不能完全抵御主机级入侵；专用用户、runner label、按需 release runner 和临时 Keychain 是当前单机约束下的最小可信边界。若未来有第二台 Mac，release runner 应迁移到独立主机。

## 3. Repository Components

### 3.1 Canonical CI command

新增 `script/ci.sh`，作为本机和 GitHub Actions 共用的唯一 CI 入口：

- `python3 script/localization_catalog_workflow.py check`
- `python3 Tests/test_localization_catalog_workflow.py --quiet`
- `bash Tests/test_copy_compiled_localizations.sh`
- `swift test`
- `xcodebuild ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

脚本使用 `/private/tmp` 或 runner temp 作为 DerivedData/module cache；失败原样返回，不隐藏或重试。workflow 不复制命令细节，避免本地与 CI 漂移。

### 3.2 Development signing

保留 `script/build_and_run.sh` 作为 macOS app bundle 构建与稳定 Dev 入口，并收紧以下合同：

- 固定预期 Team ID `72UN4PF4BL`。
- identity resolver 枚举完整候选，校验证书类型、私钥和 Team；显式 hash 优先，唯一候选可自动使用，多候选无显式选择时 fail closed 并给出不含秘密的诊断。
- Feature branch 的 `--package` 只生成带 source branch/SHA 的开发签名压缩包，不安装/启动；文件名包含短 SHA 防止覆盖。
- 只有 stable Dev install path 才触发 integration branch、clean tree、唯一 stage root 和完整 runtime gate。
- nested `PasteBuddyMCP` 先签，app 后签；`--deep` 只用于验证，不用于签名。
- 签名后验证 Bundle ID、Team ID、designated requirement、entitlements 和非 ad-hoc 状态。

### 3.3 macOS release command

新增 `script/release_macos.sh`，只接受 tag/SHA 驱动的无交互 CI 输入：

1. 校验 tag 形如 `v<semver>`，tag 指向当前 HEAD，工作树干净，HEAD 可追溯到 `origin/main`。
2. 从 release runner 临时 Keychain 解析唯一 Developer ID Application identity，并验证 Team ID。
3. 构建 app；对 nested code 从内到外签名。
4. Developer ID 签名使用 `--timestamp --options runtime`；主 app 应用经过 profile 授权的 production entitlements。
5. `codesign --verify --deep --strict --verbose=4` 与 designated requirement/entitlement 检查。
6. 使用 `ditto` 生成提交用 ZIP；`xcrun notarytool submit --wait --output-format json`。
7. 验证 accepted 状态并保存不含 credential 的 submission ID/日志摘要。
8. 对 `.app` 执行 `stapler staple` 与 `stapler validate`，重新生成最终 ZIP。
9. 对最终 ZIP 生成 SHA-256 和 provenance JSON；再次执行 `spctl --assess --type execute`。
10. workflow 使用 `gh release create` 创建不可混淆的 tag Release 并上传 ZIP、checksum、provenance。

release 脚本不安装 `/Applications/PasteBuddy.app`，不把本地运行当作公证证据。旧的 `PASTEBUDDY_SIGNING_CHANNEL=release script/build_and_run.sh --verify` 将被明确拒绝或改为非发布诊断入口，避免误称“完整 release”。

### 3.4 Self-hosted runner bootstrap

新增受信任分支专用的 `script/setup_self_hosted_runner.sh` 或等价可审计安装步骤：

- 校验 macOS/arm64/Xcode 版本和仓库 URL。
- registration token 通过 `gh api` 临时获取，不写入仓库或日志。
- runner 安装在专用用户的 `~/Library/Application Support/PasteBuddy CI/` 下。
- CI runner 注册为持久 service；release runner 默认手动/按需启动，不作为普通 PR 调度目标。
- workflow 所用 custom labels 必须与实际 runner labels 完全一致；不定义 GitHub-hosted fallback。

创建 macOS 专用用户和安装 launchd service 属于主机外部状态；实施时通过明确的系统授权执行并在文档记录卸载/撤销步骤。

## 4. GitHub Actions Workflows

### 4.1 `.github/workflows/ci.yml`

- Trigger：`pull_request`、`push` 到 `main`。
- Runner：`[self-hosted, macOS, ARM64, pastebuddy-ci, xcode-27]`。
- Permissions：`contents: read`。
- Concurrency：按 workflow/ref 分组，PR 新提交取消旧 run。
- Job：checkout 后运行 `script/ci.sh`；不使用 secrets、不上传常规构建 artifact。
- 固定 required check context，例如 `CI / verify`。

### 4.2 Hardened `.github/workflows/testflight.yml`

- 保持 manual-only `workflow_dispatch`，并增加明确的 main ref/SHA gate。
- Runner 改为 `[self-hosted, macOS, ARM64, pastebuddy-release, xcode-27]`。
- Job 绑定 `testflight` environment；单人仓库允许发起者确认。
- OIDC/GSM 在 environment gate 之后执行；ASC `.p8` 只在 runner temp 存活。
- 默认 `contents: read`, `id-token: write`；写 build tag 的独立 job/步骤才提升 `contents: write`。
- cleanup 使用 `if: always()` 删除 ASC key、archive/export 临时目录。

### 4.3 `.github/workflows/macos-release.yml`

- Trigger：`workflow_dispatch`，输入已存在的 `v*` tag 与显式确认字符串；workflow 自身复核 tag/HEAD/main ancestry。
- Runner：release labels；Environment：`macos-production`。
- Permissions：最小 `contents: write`（创建 Release）与 `id-token: write`（GCP OIDC）。
- 从 GSM 临时恢复 Developer ID `.p12`/密码、Developer ID provisioning profile 和 notarization ASC key；导入随机密码的一次性 Keychain。
- 调用 `script/release_macos.sh`；只上传最终已 stapled ZIP、checksum、provenance 到 GitHub Release。
- `if: always()` 销毁临时 Keychain 与 credential files。

## 5. GitHub Repository Governance

### 5.1 Main protection

- Require pull request before merging，当前单人仓库不要求第二个 approval。
- Require `CI / verify`，并要求 branch up to date。
- Block force pushes and deletions；require conversation resolution。
- 管理员不使用常规 bypass；紧急绕过只作为 GitHub 审计事件，并在文档要求事后补 PR/验证。

### 5.2 Environments

- `testflight`：仅 `main` 可部署；required reviewer 为 `alexj11324`，允许 self-review 以适配单人仓库；禁止无条件 admin bypass（若当前套餐/API支持）。
- `macos-production`：仅 `v*` tag；同样使用显式人工确认。
- 未来出现第二位可信协作者后，将 required reviewer 迁移为双人职责分离并启用 prevent self-review。

## 6. Secrets and Certificate Lifecycle

`general-secrets-store` 是唯一长期 secret source。计划使用/确认以下逻辑资产，具体 secret 名必须在实施时先查询现有 inventory，避免重复创建：

- ASC API private key（已有 `asc-api-key-664UJQLMB2`）。
- Developer ID Application PKCS#12。
- PKCS#12 import password。
- Developer ID production provisioning profile（CloudKit/keychain groups 需要时）。

证书 hash、Team ID、notary submission ID 和 checksum 不是秘密，可进入 provenance；私钥、密码、Keychain password、OIDC token 和完整 credential path 不进入日志。轮换时并行验证新证书后切换 secret version，再撤销旧证书。

## 7. Compatibility and Migration

- 保留 `com.alexjiang.PasteBuddy.dev`、`/Applications/PasteBuddy Dev.app`、Team ID、TCC designated requirement 和现有用户数据。
- iOS Bundle IDs、App Groups、CloudKit container、TestFlight product 不变。
- 不引入自动更新；GitHub Releases 只是发布渠道。
- 先落地 CI/scripts/tests，再注册 runner 和修改 GitHub protection；避免 protection 指向尚不存在的 required check。
- 在 CI workflow 的 PR run 首次成功后再启用 main required check。

## 8. Rollback

- Workflow/script/config 通过聚焦 commit 回滚。
- runner 可先 stop service，再从 GitHub API 移除 registration，最后删除专用 runner 目录；不删除用户 Keychain 或 PasteBuddy 数据。
- GitHub protection/environment 修改前记录完整 JSON；回滚只恢复先前设置，不删除 workflow history/Releases。
- notarization 或签名失败不得创建/覆盖正式 Release；失败产物仅留在 runner 临时目录并由 cleanup 删除。

## 9. Important Trade-offs

- Self-hosted runner 节省分钟并提供真实 Xcode/Keychain 环境，但需要主机在线、定期更新 runner/Xcode，并承担持久 runner 风险。
- 单人仓库无法真正实现双人审批；当前以 protected ref、显式 dispatch、environment gate、OIDC 和审计补偿，未来再升级职责分离。
- GitHub Releases 避免 Actions artifact storage，但 private repository 的下载仅限仓库成员；公开分发/自动更新留作后续产品决策。
