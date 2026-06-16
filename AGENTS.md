# 工具决策规则（IMPORTANT - YOU MUST follow these rules）

## 默认语义（IMPORTANT）
- IMPORTANT: 你是 Codex；除非用户明确指定其他产品/平台，不要把自己当作通用助手或其他 agent。
- IMPORTANT: 当用户提问类似“json 里面这么写吗”“怎么配”“配置项怎么写”且未指明对象时，默认按 Codex 配置回答（优先参考 `~/.codex/config.toml` 与官方 Codex 文档）。
- IMPORTANT: 仅当用户明确说明是其他工具/API/框架时，才切换到对应语境回答。

## smoke/ probe test
- IMPORTANT: 所有 test 文件,除非是正式 pipeline 所需的,一律写入 tmp 文件夹,不可以持久化保存
- IMPORTANT: 谨慎持久化 test 文件

## macOS UI/HID 验证（IMPORTANT）
- IMPORTANT: 验证 macOS 原生窗口、popover、panel、shelf、Dock 覆盖、点击关闭、拖拽、双击等交互时，禁止凭截图、经验值或硬编码坐标猜测点击位置。
- IMPORTANT: 每次 UI/HID 验证前，必须先通过 Apple 推荐的系统接口读取真实运行时几何信息，例如 `NSScreen.screens`、`NSWindow/NSPanel.frame`、Accessibility frame、`CGWindowListCopyWindowInfo` 或目标 view/window 的实际 frame。
- IMPORTANT: 点击点、拖拽起点/终点、外部点击区域、底部贴边位置必须由真实 frame 动态计算；涉及多屏、外接屏、Dock、菜单栏、Stage Manager、Spaces 或窗口跨屏时，必须先确认目标窗口所在 screen，再在该 screen 坐标系内计算。
- IMPORTANT: 如果无法拿到目标窗口或 view 的真实 frame，不允许继续用猜测坐标做结论；必须先补充可观测性、日志、Accessibility 标识、测试 hook 或 AppKit 调试入口。
- IMPORTANT: 对 Paste/PasteBuddy 底部 shelf 这类贴屏底部交互，必须验证它贴的是目标 screen 的完整 `frame` 底边，而不是 `visibleFrame`；不得因为 Dock 或多屏布局而绕开底部，也不得用固定主屏坐标假设 shelf 位置。

## macOS 签名与权限验证（IMPORTANT）
- IMPORTANT: PasteBuddy 日常开发必须使用稳定的 `Apple Development` 签名身份；禁止使用 ad-hoc、`-`、`Sign to Run Locally`。
- IMPORTANT: 发布、安装包、真实用户路径或需要验证 Accessibility/TCC 权限持久性的测试，必须使用 `Developer ID Application` 签名，并安装到 `/Applications/PasteBuddy.app` 后验证。
- IMPORTANT: 如果构建命令、脚本、环境变量或 Xcode 设置试图使用 ad-hoc 签名，必须立即拒绝并改为稳定签名身份，不要继续运行 UI/HID 权限验证。
- IMPORTANT: `script/build_and_run.sh` 是本仓库标准构建入口；默认 `PASTEBUDDY_SIGNING_CHANNEL=development`，发布验证显式使用 `PASTEBUDDY_SIGNING_CHANNEL=release`。

## 遇到不认识的东西时
1. 先想：我知道这是什么吗？
2. 不知道 → Exa 搜 1 次了解它是什么。禁止用 find_helpful_skills 当搜索引擎。
3. 知道了再判断下一步：
   - 要写进代码的库 → context7 查文档
   - 要当工具/服务接入 → Exa 搜 "[名称] MCP server claude code" 看有没有 MCP/plugin
   - 需要结构化工作流指南 → 这时候才用 find_helpful_skills
   - 只需要信息 → Exa

## find_helpful_skills 使用限制
- IMPORTANT: find_helpful_skills 只用于查找"教我怎么完成某类任务的结构化指南"（如 webapp-testing、frontend-design）
- 禁止用它来搜索工具/服务/库的信息（如搜 "Sentry error monitoring"）
- 禁止一次发 3 个相似 query 并行搜索，1 次精准查询就够
- 如果不确定有没有 skill，先用 `npx claude-skillseek` 搜

## 工具选择速查
| 需求 | 工具 |
|------|------|
| 网络搜索 | Exa（web_search_exa / get_code_context_exa） |
| 库/框架文档 | context7（resolve-library-id → query-docs） |
| 浏览器调试 | chrome-devtools MCP |
| GitHub 操作 | github MCP |
| 错误监控 | Sentry MCP + getsentry/sentry-for-claude 插件 |
| 找 skill | npx claude-skillseek |

# 用户全局偏好（IMPORTANT - YOU MUST follow these rules）

## 搜索工具
- IMPORTANT: 所有网络搜索必须使用 Exa 工具（web_search_exa、get_code_context_exa、company_research_exa）。禁止使用 WebSearch 工具。

## 工具使用习惯
- IMPORTANT: 回答技术问题前，先考虑是否有合适的 MCP 工具可用，不要跳过直接回答。
- IMPORTANT: 遇到不认识的工具/服务/库，先用 Exa 搜 1 次了解它是什么，再决定下一步。详见 tool-decision.md。
- 查文档时优先用 context7 查库文档。
- ML/AI 领域问题同样遵循 tool-decision.md 的决策流程，不特殊对待。
- IMPORTANT: 用户明确要求“直接运行/验证/测试”时，不再反复询问选项或是否执行，默认先执行最小、最安全的验证步骤。

## 云端默认配置
- IMPORTANT: 你的默认云端配置是 OCI（Oracle Cloud Infrastructure）的 Always Free 方案；在用户未明确指定云厂商/套餐时，默认按 OCI Always Free 约束给出建议与配置。
- IMPORTANT: 你的默认域名是 `nebula-spaces.com`（托管在 Cloudflare）；在用户未明确指定域名时，默认使用该域名进行 DNS、TLS、反代、Workers 路由等相关配置建议。
- IMPORTANT: 以后云端新增服务默认使用子域名方案（`<service>.nebula-spaces.com`）；除非用户明确要求根域名或其他域名。
- IMPORTANT: 仓库、脚本、`.env`、配置文件中如果已有明文 API key 只做提醒，只要没有明确 prompt 让你做修改，不得做任何修改

## 密钥管理（Secrets）
- IMPORTANT: 凡是遇到密钥、Token、凭据、密码、证书等敏感信息，优先搜索和使用 `gsm`（Google Secrets Manager）流程/工具，不要先散落到本地文件或临时变量。
- IMPORTANT: 所有密钥统一存放在 `general-secrets-store` 项目；禁止新增到其他仓库、脚本、环境变量文件（除非明确是临时调试且会立即清理）。
