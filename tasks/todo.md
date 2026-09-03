# 设置界面：把上一轮重构留下的问题改完

## Goal
上一个 session 在 `c08b3e9` 完成了「设置界面去工程化」重构，但崩在了「装完之后逐页肉眼验证」这一步。这一轮把没做完的验证补上，并修掉验证中你直接指出的 5 个问题。

## 上一轮方案里已经落地的（这次逐页确认过，不用再动）
- [x] 面板样式改方位词：设置、菜单栏、无障碍播报三处同时是「横向面板 / 竖向面板」
- [x] 「通用 › 后台运行」和「隐私 › 捕获已启用」的重复开关只剩通用页一个，改名「记录剪贴板内容」
- [x] 三个 `org.nspasteboard.*` 开关合并成「不记录密码框和临时内容」，帮助文本直说后果
- [x] 隐私页分段控件删除，排除应用列表升为独立 Section
- [x] 通用页底部显示 版本 / 构建 / commit（`版本 0.0.0-dev（构建 174 · ae6430c6）`）

## 这一轮修的（都是你在跑起来的 app 里指出的）
- [x] **「高级」折叠区只有箭头能点** —— `DisclosureGroup` 的命中区只覆盖 chevron 和 label，行的其余部分对指针是死的。按你说的「直接列出来」，改成普通 Section「更多规则」，不再折叠
- [x] **存储上限的数字不合逻辑** —— 预设是二进制（512 MiB / 1 GiB…），而 `ByteCountFormatter` 的 `.file` 按十进制算，所以每个都印成小数，最大一档还给到 107 GB。预设改成十进制 500 MB / 1 / 2 / 5 / 10 GB，`StorageConfiguration` 默认值一起改，并加 schema 3 迁移：只把仍停在旧 512 MiB 默认值的安装改成 1 GB，用户自己选过的上限不动。顺手把 `migrateIfNeeded` 改成分步迁移，否则 v2 快照会重复执行 v2 那次敏感文本重置
- [x] **删掉「不记录从 iPhone、iPad 复制的内容」** —— 连同设置项和背后的 pasteboard marker 一起删；隔空剪贴板的内容就是剪贴板内容
- [x] **「0.0 兆字节」** —— zh-Hans 把 MB 译成了「兆字节」，两种语言都用 MB
- [x] **排除应用那一块的框** —— Section 的框里又套了一个 `.listStyle(.bordered)` 的 List，页面滚动条里再嵌一个滚动条，底部还切掉半行。改成普通设置行，每行自带删除按钮，末尾一个「添加 App…」；顺带：Launch Services 解析得出的 App 显示真名和图标（原来 `com.apple.keychainaccess` 标题和副标题印两遍、图标是空框），没装的 App 用虚线图标，说明文字从列表下面挪到列表上面
- [x] **体积输入框没有边框** —— 改成标准 `.roundedBorder` 输入框
- [x] 清掉重构遗留的 12 个孤儿 localization key（它们带着旧的工程化文案）

## Verification
- [x] `swift test`（隔离 scratch-path）全绿：169 + 344 tests，0 failures
- [x] `script/ci.sh` 端到端（本地化校验 + macOS 编译 + 全部测试 + iOS `xcodebuild`）
- [x] `script/build_and_run.sh --verify` 安装到 `/Applications/PasteBuddy Dev.app`，Info.plist 的 `PasteBuddySourceCommit` 与 HEAD 一致
- [x] 在跑起来的 app 里逐页截图确认：通用页（含版本行）、隐私页三屏（记录哪些内容 / 不记录这些 / 不记录这些 App / 存储与安全 / 更多规则）

## 新增测试
- `testStorageCeilingMigrationReplacesTheLegacyBinaryDefault` / `...LeavesADeliberateChoiceAlone`：迁移只动旧默认值
- `testMigratingFromV2DoesNotReapplyTheV1SensitiveTextReset`：分步迁移不重复执行旧步骤
- `testStorageCeilingDefaultIsARoundDecimalNumber`：默认上限格式化出来是 "1 GB"
- 契约测试更新：不再有 `DisclosureGroup` / `selectedRowID` / `.listStyle(.bordered)` / `label.ignore_remote_clipboard`

## 这一轮还修的（你后面追加的反馈）
- [x] **排除列表里有重复、还有没装的 App** —— 根因是出厂默认写了两份平行名单：`defaultExcludedApplicationNames = ["1Password", "Passwords", "Keychain Access"]` 和 5 个 bundle id，而这三个名字对应的 App 早已被 bundle id 覆盖，所以每个都显示两行。更糟的是名字规则比对的是 App 的**本地化名称**，中文系统上 "Passwords"/"Keychain Access" 永远匹配不上，是彻底的死规则。改成出厂不预设任何名字规则（bundle id 覆盖同样的 App，且不受语言影响），schema 4 迁移把老安装里这三个名字删掉；用户自己通过选择器加的名字（存的是 App 自己的显示名）照常生效并与该 App 合并成一行
- [x] 剩下两个确实没安装的密码管理器（`com.agilebits.onepassword7`、`com.bitwarden.desktop`）行内标注「这台 Mac 上没有安装」，不再让人猜一个没图标的反向域名字符串是干嘛的

## 已完成
- [x] 推到 `codex/integrated-delivery`（PR #36），`26116a3`；本地 `script/ci.sh` 在这个 commit 上 EXIT=0
