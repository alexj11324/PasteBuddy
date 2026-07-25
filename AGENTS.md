# 工具决策规则（IMPORTANT - YOU MUST follow these rules）

## 默认语义（IMPORTANT）
- IMPORTANT: 你是 Codex；除非用户明确指定其他产品/平台，不要把自己当作通用助手或其他 agent。
- IMPORTANT: 当用户提问类似“json 里面这么写吗”“怎么配”“配置项怎么写”且未指明对象时，默认按 Codex 配置回答（优先参考 `~/.codex/config.toml` 与官方 Codex 文档）。
- IMPORTANT: 仅当用户明确说明是其他工具/API/框架时，才切换到对应语境回答。
- IMPORTANT: 排查 Codex / MCP 配置时，禁止扫描整个 `~/.codex`；只能读取明确目标文件（例如 `~/.codex/config.toml`）或用户指定路径，避免插件缓存和日志导致卡顿或泄露无关信息。

## 删除语义（IMPORTANT）
- IMPORTANT: 当用户明确要求删除某个地方、布局、格局、结构或入口时，必须在代码层面彻底删除对应实现、引用、状态和布局占位；禁止仅用隐藏、透明、禁用、条件恒 false、移出屏幕或零尺寸等方式保留旧代码。
- IMPORTANT: 只有用户明确要求临时隐藏、保留开关、保留回滚入口或 feature flag 时，才允许保留相关代码；否则按彻底删除处理。

## smoke/ probe test
- IMPORTANT: 所有 test 文件,除非是正式 pipeline 所需的,一律写入 tmp 文件夹,不可以持久化保存
- IMPORTANT: 谨慎持久化 test 文件
- IMPORTANT: 进行测试时，特别是涉及截图自动化的程序，必须使用 Computer Use 操作真实界面；不允许使用脚本驱动截图自动化，因为脚本会干扰正常操作。

## PasteBuddy 国际化/本地化工作流（IMPORTANT）
- IMPORTANT: PasteBuddy 新增用户可见文案必须使用语义 key（例如 `action.save_text`、`label.mobile_setup`、`format.items_count`），不要把完整英文句子直接写成 UI key。
- IMPORTANT: `PasteBuddyCore` 或非 SwiftUI view 层生成的用户可见文案必须使用 `PasteBuddyLocalization.string/format`，并提供与英文 catalog 值一致的 `defaultValue`。
- IMPORTANT: 翻译维护必须优先走 `script/localize_string_catalog_with_dify.py`；Dify 负责翻译/审稿，`script/localization_catalog_workflow.py` 负责同步 `Localizable.strings` 与 `Localizable.xcstrings`。
- IMPORTANT: 只做本地同步时运行 `python3 script/localize_string_catalog_with_dify.py --skip-dify`；提交前至少运行 `python3 script/localization_catalog_workflow.py check` 和 `swift test --filter LocalizationResourceTests`。
- IMPORTANT: iOS target 必须继续使用 `Sources/PasteBuddy/Resources/Localizable.xcstrings`；不要重新把 iOS 资源阶段切回 `Localizable.strings`。
- IMPORTANT: Dify API key 只能从 `DIFY_WORKFLOW_API_KEY` 或 Google Secret Manager `general-secrets-store/dify-pastebuddy-localization-workflow-api-key` 读取，禁止写入仓库、`.env`、临时脚本常量或长期本地文件。

## macOS UI/HID 验证（IMPORTANT）
- IMPORTANT: 验证 macOS 原生窗口、popover、panel、shelf、Dock 覆盖、点击关闭、拖拽、双击等交互时，禁止凭截图、经验值或硬编码坐标猜测点击位置。
- IMPORTANT: 每次 UI/HID 验证前，必须先通过 Apple 推荐的系统接口读取真实运行时几何信息，例如 `NSScreen.screens`、`NSWindow/NSPanel.frame`、Accessibility frame、`CGWindowListCopyWindowInfo` 或目标 view/window 的实际 frame。
- IMPORTANT: 点击点、拖拽起点/终点、外部点击区域、底部贴边位置必须由真实 frame 动态计算；涉及多屏、外接屏、Dock、菜单栏、Stage Manager、Spaces 或窗口跨屏时，必须先确认目标窗口所在 screen，再在该 screen 坐标系内计算。
- IMPORTANT: 如果无法拿到目标窗口或 view 的真实 frame，不允许继续用猜测坐标做结论；必须先补充可观测性、日志、Accessibility 标识、测试 hook 或 AppKit 调试入口。
- IMPORTANT: 对 Paste/PasteBuddy 底部 shelf 这类贴屏底部交互，必须验证它贴的是目标 screen 的完整 `frame` 底边，而不是 `visibleFrame`；不得因为 Dock 或多屏布局而绕开底部，也不得用固定主屏坐标假设 shelf 位置。
- IMPORTANT: 每一次修复 macOS UI、视觉、HID、window/panel/shelf、滚动条、背景裁剪、hover/focus、hit testing 或布局问题后，不能只运行 `swift build` / `swift test` 就声称成功；必须重新编译并重新打开真实 app，再做运行时视觉验证。
- IMPORTANT: PasteBuddy 视觉/UI 修复的完成门槛是：运行 `script/build_and_run.sh --verify` 安装并启动新编译的 `/Applications/PasteBuddy Dev.app`，确认输出包含 `accessibilityTrusted=true`、`stableLaunchPathMatched=true`、正确 `bundleIdentifier`、`bundlePath` 与 `signingChannel=development`，然后重新触发受影响的 UI（例如 Shelf/Panel/Popover），基于真实 window/view frame 截图或直接观察确认用户可见问题已经消失。
- IMPORTANT: 如果没有重新打开新编译 app、没有触发受影响 UI、没有视觉验证原始症状已经消失，只能报告“代码已改但视觉结果未验证”，禁止说“已修复/完成/成功”。
- IMPORTANT: PasteBuddy 主窗口/历史窗口只能由用户明确手动触发；验证 Shelf、菜单栏图标、popover、状态菜单或后台运行时，禁止为了方便主动打开主窗口，也禁止在菜单栏状态菜单里新增“Open PasteBuddy”这类直接打开主窗口入口。需要查看主窗口时必须先得到用户明确授权。

## PasteBuddy Shelf 状态隔离与性能（IMPORTANT）
- IMPORTANT: Shelf 顶部 `Clipboard` / `Paste Stack` / Pinboard chip 只是 Shelf 内部浏览切页时，禁止直接写全局 `store.selectedScope`；必须使用 Shelf 本地状态（如 `shelfScope`）驱动 chip 高亮、空态、快捷键和 `store.filteredItems(for:)` 查询。
- IMPORTANT: 不要让 Shelf 内部切换触发主窗口 `ItemListView`、CommandMenu 或 `mainListItemsSnapshot` 的全局刷新；尤其是 Pinboard -> Clipboard 不得因为全局 scope 改动而让 History 路径在主线程扫描/排序完整 `snapshot.items`。
- IMPORTANT: 如果确实需要把 Shelf 操作同步到全局 store，只能在明确的用户动作后同步（例如选择/复制/粘贴/删除），并确认不会把一次 chip 点击扩散成两轮 refresh 或完整 History 重算。
- IMPORTANT: 修复 Shelf 卡顿时必须优先排查全局状态副作用、`queryRevision` bump、`selectedItemsInDisplayOrder`、`mainListItemsSnapshot` 和命令菜单 disabled 计算，不要只盯着 Shelf card 动画或 collection reload。
- IMPORTANT: 为这类修复添加正式回归测试，验证 scoped 查询/快捷键不会 mutate `selectedScope` 或 bump 不必要的 `queryRevision`；不要只靠手动点击感觉判断。
- IMPORTANT: Shelf / Side Panel 卡片必须单击立即选中，只有双击执行粘贴；单击识别必须与双击识别并行，禁止重新使用会等待双击判定后才触发 selection 的互斥或成对 `.onTapGesture`。相关修改必须验证单击高亮无延迟且双击仍只执行粘贴。
- IMPORTANT: Shelf 与 Side Panel 的复制确认必须共用同一条成功反馈路径；只有系统 pasteboard 写入返回成功后才能显示一个可更新/合并的非激活 HUD，禁止在写入前或写入中显示、堆叠多个 HUD、抢焦点或延迟复制。HUD 必须使用本地化数量文案、原生 material 与辅助功能语义，遵循 Reduce Motion，并自动消失。

## PasteBuddy Shelf Liquid Glass 背景（IMPORTANT）
- IMPORTANT: Shelf 底板、搜索框、空态/提示卡片等 custom glass surface 必须共享同一个 `ClipboardShelfGlass.defaultTintOpacity` 默认逻辑；禁止给搜索框或局部背景保留单独的 opacity state、slider 或调试控件。
- IMPORTANT: 不要把截图里的百分比或临时调试滑杆显示值当作设计经验值；需要改 Shelf 毛玻璃不透明度时，只调整共享的 `ClipboardShelfGlass.defaultTintOpacity`，并让搜索框和整体背景同源生效。
- IMPORTANT: Shelf 毛玻璃当前经验是用原生 `glassEffect` 配合 `.thickMaterial` 预模糊和 `ClipboardShelfGlass.detailSuppressionOpacity` 压掉背后高频文字细节；不要为“更像 glass”移除这层细节抑制。

## macOS 视觉边界与背景裁剪（IMPORTANT）
- IMPORTANT: 胶囊、圆角按钮、圆角 segmented/tab item、toolbar pill 等控件外面不允许露出矩形灰色背景或方形容器底色。
- IMPORTANT: 这类问题不要称为“遮罩”并继续叠层修补；工程上按 `background bleed`（背景溢出/漏出）、`unclipped background`（背景未裁剪）、`cell background` 或 `selection highlight background` 排查。
- IMPORTANT: 修复时优先消除或透明化外层 cell/container background，并确保背景、选中高亮和 hover/focus 状态被同一个圆角边界裁剪；禁止新增一个矩形灰底作为胶囊外框。
- IMPORTANT: 对 NSCollectionView/NSTableView/SwiftUI-NSHostingView 混合控件，必须检查 item/cell/backgroundView/selection layer/hosting view 的背景色和 clipping，不允许让 AppKit 默认矩形背景从 SwiftUI 圆角控件外漏出。

## macOS 签名与权限验证（IMPORTANT）
- IMPORTANT: PasteBuddy 日常开发必须使用稳定的 `Apple Development` 签名身份；禁止使用 ad-hoc、`-`、`Sign to Run Locally`。
- IMPORTANT: 发布、安装包、真实用户路径或需要验证 Accessibility/TCC 权限持久性的测试，必须使用 `Developer ID Application` 签名，并安装到 `/Applications/PasteBuddy.app` 后验证。
- IMPORTANT: 如果构建命令、脚本、环境变量或 Xcode 设置试图使用 ad-hoc 签名，必须立即拒绝并改为稳定签名身份，不要继续运行 UI/HID 权限验证。
- IMPORTANT: `script/build_and_run.sh` 是本仓库标准构建入口；默认 `PASTEBUDDY_SIGNING_CHANNEL=development`，发布验证显式使用 `PASTEBUDDY_SIGNING_CHANNEL=release`。

## PasteBuddy 集成交付与共享状态（IMPORTANT）
- IMPORTANT: `/Applications/PasteBuddy Dev.app` 只能由干净的 `codex/integrated-delivery` 分支通过 `script/build_and_run.sh` 安装；安装包必须记录 source branch/commit，安装后保持 user immutable，其他 worktree 禁止解除保护或覆盖。
- IMPORTANT: isolated worktree 只允许运行 build/test。需要运行时基线时必须使用独立临时 bundle id、独立数据目录且不得启动第二个菜单栏实例；禁止把对照构建安装为 `PasteBuddy Dev.app`。
- IMPORTANT: stable install 验收必须同时证明：恰好一个 `.dev` 进程来自 `/Applications/PasteBuddy Dev.app`、只打开 `Application Support/PasteBuddy Dev/clipboard.sqlite`、权威历史跨 relaunch 保留，且 Info.plist source commit 是当前交付 HEAD。
- IMPORTANT: standard storage 下，含 snapshot metadata 的 SQLite 是 history 读取权威；开发 bundle 的 pbstore/SQLite 必须同在 `PasteBuddy Dev`，初始化失败必须可见并 fail closed，禁止回退 `/tmp`、生产目录或 stale snapshot。
- IMPORTANT: link preview title、image asset ID 与 SQLite indexed asset reference 必须由同一次 store/repository save 提交；UI 只从共享 store/repository hydration 读取，禁止 surface 自建第二份 metadata cache。
- IMPORTANT: accessory app 必须在任何 history/database `await` 之前创建 status item；生命周期回归必须验证调用顺序和稳定安装后的存活。

## iOS TestFlight 发布固定流程（IMPORTANT）
- IMPORTANT: PasteBuddy iOS/TestFlight 发布必须使用 `script/push_testflight.sh`；不要只手动 `git push`，也不要绕过 CI 手动上传 App Store Connect。
- IMPORTANT: 固定顺序是本地 `swift test` + iOS simulator compile 通过后，push 当前 `main` HEAD；`.github/workflows/testflight.yml` 随 push 接管 archive、签名、上传 App Store Connect/TestFlight，并写入 `ios-build-*` tag。
- IMPORTANT: App Store Connect `.p8` 私钥只允许通过 Google Secret Manager `general-secrets-store` 里的 `asc-api-key-664UJQLMB2` 读取；禁止写入仓库、`.env`、临时脚本常量或长期本地文件。
- IMPORTANT: 如果工作区有无关未提交改动，先确认要发布的 HEAD 已提交；只有在这些脏文件明确不属于本次发布时才可给脚本加 `--allow-dirty`，脚本会用临时 git worktree 验证即将 push 的 HEAD，而不是验证脏工作区。
- IMPORTANT: 发布后必须等待 GitHub Actions 的 `Upload TestFlight` workflow 完成；脚本用稳定 workflow file `testflight.yml` 查询/触发 run，并报告 ASC/TestFlight 上传是否成功；失败时先看 workflow 日志，不要重复推送造成重复 build。

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
