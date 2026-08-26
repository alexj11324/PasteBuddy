# 标准化 Apple 签名与 CI/CD 流程

## Goal

建立一套可审计、可复现且符合 Apple 与 GitHub Actions 最佳实践的 PasteBuddy 签名和 CI/CD 体系：开发者不需要切回 `main` 才能完成开发签名构建；共享稳定 Dev 安装仍只由受控集成提交更新；iOS TestFlight 与 macOS 站外发布只从受保护来源在 CI 中完成，并保留准确的源码、签名、公证和发布证据。

## Background and Confirmed Facts

- 当前 `/Applications/PasteBuddy Dev.app` 使用 `Apple Development`、Team ID `72UN4PF4BL` 和 `com.alexjiang.PasteBuddy.dev`，在真实用户 Keychain 会话中通过 `codesign --verify --deep --strict`；现有开发签名不是 ad-hoc。
- `script/build_and_run.sh` 只在覆盖 `/Applications/PasteBuddy Dev.app` 时要求干净的 `codex/integrated-delivery`；这是共享稳定安装的提升门禁，不是 Apple 的签名要求。
- 任意分支已有 `--package` 构建签名能力，但开发构建、稳定 Dev 提升和正式发布仍混在同一个脚本与默认安装语义中。
- macOS `release` 当前只选择 `Developer ID Application`，没有安全时间戳、Hardened Runtime、notary submission、ticket stapling 或完整发布产物验证。
- identity 自动选择只按证书名称前缀取第一个结果；当前 Keychain 存在两个同名有效 `Apple Development` identity，且没有在所有路径上强制 Team ID。
- iOS 工程使用 Xcode Automatic Signing；现有 `testflight.yml` 通过 GitHub OIDC 从 `general-secrets-store` 临时取得 App Store Connect 私钥，然后 archive/export/upload。
- 仓库当前只有 TestFlight 发布 workflow，没有 PR/main CI workflow，也没有 macOS release workflow。
- GitHub `main` 当前没有 branch protection；只有无保护规则的 `copilot` environment，没有 TestFlight 或 macOS production environment。
- `testflight.yml` 可从任意 `workflow_dispatch` ref 启动；main 限制只存在于本地 `script/push_testflight.sh`，不是服务端强制门禁。
- GitHub 官方当前说明 self-hosted runner 不消耗 GitHub-hosted Actions 分钟；本仓库是 private repository，适合使用仓库级本地 macOS runner，但仍需隔离不受信任代码与发布密钥。
- 当前执行主机为 Apple Silicon (`arm64`)、macOS 27.0、Xcode 27.0；GitHub API 显示 PasteBuddy 仓库尚未注册 self-hosted runner，系统中也没有正在运行的 Actions Runner service。
- 用户已确认采用“GitHub Actions 负责编排与 required checks，本机 macOS self-hosted runner 负责实际执行”的本地 CI 模式。
- 仓库当前没有 GitHub Releases，也没有 Actions artifacts，尚无既定的 macOS 公证产物分发惯例。
- 仓库没有 Sparkle、appcast 或其他 macOS 自动更新实现；选择 GitHub Releases 只会建立版本化公证产物的发布/下载渠道，不会自动改变客户端更新行为。
- 用户已确认 macOS 公证产物发布到 GitHub Releases，以避免 Actions artifact 存储额度并保留 tag/commit/checksum/provenance。
- GitHub API 显示仓库当前只有 `alexj11324` 一个协作者；保护规则不得要求第二人审批而永久锁死单人维护流程。

## Requirements

### R1. 明确签名与发布渠道

- 定义并记录 `development`、`testflight`、`developer-id` 三个渠道；每个渠道必须明确证书类型、Bundle ID、Team ID、entitlements/provisioning、构建来源、安装/上传目标和验证命令。
- 禁止 ad-hoc、`Sign to Run Locally` 或模糊证书回退被当作开发运行、TCC 验证或正式发布证据。
- 签名对象是确定的构建产物和 commit；Git 分支只负责来源/提升策略，不得作为“能不能签名”的技术前提。

### R2. 开发签名与稳定 Dev 提升分离

- 任意已提交分支都能生成以 `Apple Development` 签名、带 commit provenance 的非安装构建/包，不要求 checkout `main` 或 `codex/integrated-delivery`。
- isolated worktree 默认只允许 build/test/package，不得覆盖稳定 App、复用生产数据目录或启动第二个菜单栏实例。
- `/Applications/PasteBuddy Dev.app`、`com.alexjiang.PasteBuddy.dev`、`pastebuddy-dev://` 和稳定 Dev 数据目录仍是单一共享控制目标，只能由干净的 `codex/integrated-delivery` 提升。
- 稳定 Dev 验收继续证明：一个进程、稳定 bundle path、正确 Bundle ID/Team ID/signing requirement/source commit、`accessibilityTrusted=true` 和 `stableLaunchPathMatched=true`。

### R3. 确定性证书和 entitlement 验证

- 所有签名渠道必须校验 Team ID `72UN4PF4BL`、证书类型、有效私钥、Bundle ID 和签名 requirement。
- 多个同等候选 identity 时必须显式选择或可见失败，不得依赖 Keychain 返回顺序。
- 私钥只存在于 macOS Keychain 或 CI 临时 Keychain；仓库和日志不得保存或输出私钥、密码、ASC 私钥内容或证书包。
- CloudKit/keychain access group 等受限 entitlement 必须由匹配渠道的 provisioning profile 授权，并在签名后再次校验。

### R4. macOS Developer ID 发布链

- 正式 macOS 产物必须从受保护 tag/commit 在 CI 中构建，并对所有 nested code 从内到外签名。
- Developer ID 签名必须启用 Hardened Runtime 与安全时间戳。
- 发布必须执行 `codesign` 严格校验、`spctl` Gatekeeper assessment、Apple notary submission、notary log 检查、ticket staple 和 staple validation。
- macOS 发布 job 可在受控的本地 self-hosted macOS runner 执行，但必须与普通 CI job 分离：发布 job 先通过 owner-only tag/确认 gate 与 environment 来源策略，才使用 GitHub OIDC 从 `general-secrets-store` 临时取得 Developer ID 和 notarization 输入，导入一次性临时 Keychain，结束时清理。
- 每个产物必须记录 source SHA、版本、签名渠道、Team ID、公证 submission ID 和校验结果，并生成不可混淆的 artifact 名称与 SHA-256。

### R5. PR 与 main 持续集成

- 新增 owner 放行的 GitHub Actions CI：维护者显式提交一个完整 commit SHA 后，本地 self-hosted runner 才执行该 SHA，并通过 Checks API 把稳定的 `CI / verify` 结果写回该 commit。
- CI 至少覆盖 Swift tests、本地化 catalog check、iOS Simulator 无签名编译，以及签名/发布脚本的静态或单元策略测试。
- CI 不读取发布密钥，不使用 `pull_request_target`，也不因 PR 事件自动在个人 Mac 上执行代码；只有仓库 owner 对具体 SHA 的显式放行才可触发执行。CI 不安装或启动共享 PasteBuddy Dev App。
- CI job 名称稳定，可被 main branch protection 设为 required checks。
- 实际编译测试默认在仓库级本地 macOS self-hosted runner 上执行，以避免 GitHub-hosted minutes；workflow 仍由 GitHub 触发并回写 required check 状态。
- runner 必须使用专用 label、独立工作目录和单独 macOS 用户/权限边界；普通 CI runner 不得常驻解锁 Developer ID 私钥，不得访问生产数据目录或启动 PasteBuddy 菜单栏实例。

### R6. iOS TestFlight CD 加固

- TestFlight 继续使用 Xcode Automatic Signing、ASC API key 与 GitHub OIDC/GSM，不把 `.p8` 持久化到仓库或长期 runner 文件。
- workflow 自身必须校验只接受 `main` 的已提交 SHA，不能只依赖本地包装脚本传入正确 ref。
- TestFlight 上传 job 必须绑定来源受限 environment，并在取得发布 credential 之前经过 owner-only SHA/确认门禁。
- build number/tag 写回必须可审计、幂等，并只授予需要写 tag 的步骤/作业 `contents: write`。
- TestFlight archive/export/upload 可运行在受保护的本地 release runner，因此不依赖 GitHub-hosted macOS minutes；runner 离线时 workflow 应保持 queued，而不是回退到收费 runner。

### R7. GitHub 仓库保护和 CD 治理

- 为 `main` 配置 branch protection：禁止 force push/delete，要求 PR、required CI checks 和分支最新；管理员绕过策略必须明确。
- 创建 TestFlight 与 macOS production environments，限制允许部署的 branch/tag；正式发布前使用 owner-only dispatch 与确认输入。当前 private-repository 套餐 API 不支持 required reviewers/wait timer，升级套餐后再增加第二位可信 reviewer 与 prevent self-review。
- workflow/action 权限遵循最小权限；云端访问使用 OIDC 短期身份。
- CI/CD 配置变更与仓库设置变更都必须在最终验收中读取 GitHub 当前状态复核，不能只以 YAML 存在为完成证据。

### R8. 文档、迁移与回滚

- 更新开发签名、TestFlight 和 macOS 发布文档，提供日常命令、渠道矩阵、证书责任、失败诊断和轮换/撤销流程。
- 保留现有稳定 Dev Bundle ID、路径、Team ID、TCC identity、用户数据和共享 capability；不得通过改 Bundle ID 绕过已有权限。
- 迁移期间不得发布未公证 macOS release；旧的本地 release 命令要么变为显式受限的验证入口，要么可见拒绝并指向 CI。
- 所有改变应形成聚焦提交；不得包含当前 Powersync 或 local-AI Trellis 的无关脏文件。

## Acceptance Criteria

- [ ] AC1: 任意干净 feature commit 可运行非安装的开发签名构建/打包命令，输出 Apple Development、预期 Team ID/Bundle ID、source SHA 和严格签名校验；无需切换到 main/integrated-delivery。
- [ ] AC2: feature branch 试图覆盖 `/Applications/PasteBuddy Dev.app` 时稳定失败；干净 `codex/integrated-delivery` 经标准命令可重新安装并通过完整稳定 Dev runtime diagnostics。
- [ ] AC3: 多个匹配 identity 未显式消歧时不会静默选择错误身份；错误 Team、证书类型、Bundle ID、profile 或 entitlement 都有测试覆盖并 fail closed。
- [ ] AC4: owner 放行具体 PR/main SHA 后，CI 在 GitHub 上真实运行通过并把 `CI / verify` 写回同一 SHA，覆盖 Swift、本地化、iOS Simulator compile 和签名策略测试；job 无发布 secrets，除 `checks: write` 外无写权限。
- [ ] AC5: TestFlight workflow 从非 main ref 被服务端拒绝，main 发布通过受保护 environment、OIDC/GSM、archive/export/upload，并保留 run URL、SHA 与上传结果。
- [ ] AC6: macOS release workflow 从受保护发布来源生成 Developer ID 签名、Hardened Runtime、安全时间戳、已公证并 stapled 的产物；`codesign`、`spctl`、`stapler validate` 和 checksum 全部通过。
- [ ] AC7: GitHub API 证明 main branch protection、required checks、禁止 force push/delete，以及 TestFlight/macOS environments 的来源限制已生效；套餐不支持的 reviewer 规则明确记录为未启用，不能冒充已生效。
- [ ] AC8: 仓库扫描未发现新增私钥、密码、`.p8`、`.p12` 或明文 credential；临时 Keychain/credential 文件在 CI 结束时清理。
- [ ] AC9: 文档给出清晰渠道矩阵和开发/发布命令；旧文档不再把本地 Developer ID `--verify` 描述成完整 macOS 正式发布。
- [ ] AC10: 工作树只包含本任务文件；相关测试、workflow syntax、真实 Dev runtime 和可执行的 CD 路径完成与风险相匹配的验证并形成聚焦提交。
- [ ] AC11: 所有 CI/CD workflow 明确选择专用 self-hosted macOS labels，GitHub billing 页面/runner 状态证明没有回退使用 GitHub-hosted macOS minutes；runner 离线时任务只排队。

## Out of Scope

- Mac App Store 分发渠道；当前仓库的 macOS 正式渠道是 Developer ID 站外分发。
- 改变 iOS App Store 产品、Bundle ID、Team、CloudKit container 或 TestFlight 外部测试组策略。
- 替换 GitHub Actions/GCP Secret Manager、迁移云厂商，或引入额外的第三方云 runner 服务。
- UI、功能逻辑、PowerSync、AI annotation、数据库或用户数据迁移。

## Key Decisions

- GitHub Actions 作为控制面，实际编译、测试和发布运行在本机 macOS self-hosted runners。
- 普通 CI 采用 owner 对完整 commit SHA 的显式放行；PR 事件本身不会在个人 self-hosted Mac 上自动执行代码。
- 普通 PR/main CI 与发布执行使用不同 runner label、工作目录和权限边界；普通 CI 永远不接触发布密钥。
- macOS 正式渠道为 Developer ID 站外分发，公证产物发布到 GitHub Releases；本次不引入客户端自动更新。
- 当前套餐不支持 private repo Environment required reviewers；以 owner-only dispatch、确认字符串和 deployment branch/tag policy 补偿，升级套餐且增加第二位可信协作者后再启用禁止自批。
- `codex/integrated-delivery` 继续拥有稳定 Dev 安装提升权，`main`/受保护 tag 拥有正式发布权；签名构建本身不要求切换分支。
