# 0.2.0／build 2 候选版验证

2026-10-12，最终整合 I1 修复。完整原生回归为 **391／391（Core 181＋App 210）**，0 failures、0 warnings。使用新的测试 scratch 与新的 arm64／x86_64 release 构建目录，包版本与最低系统来自 `packaging/release-version.json`。完整网站最终结果及每项门禁见[随包网站公开验证摘要](../../site/downloads/verification.json)。

[发行元数据](../../site/downloads/release.json)记录实际 DMG SHA／大小、架构、最低系统、签名状态与测试记录；[构建输入清单](../../site/downloads/build-source.json)与 App 内 `Contents/Resources/build-source.json` 一致。私有源码仓库不妨碍 Pages 的 `downloads/verification.json` 和 `downloads/build-source.json` 被访问。

## 本轮执行与证据

- `scripts/verify-inkpeg.sh <新的目录>`：先执行发行契约检查，然后 clean-env 完整 Swift 测试、Universal 构建、DMG 创建与校验，保留 COMMAND／OUTPUT／EXIT。测试中预期的损坏 PDF 回退产生一条 CoreGraphics 诊断，不是 warning，也未隐藏。
- `scripts/release-tools.py inspect --app <App> --out <记录>`：分别读取两个 Mach-O slice 的最低系统，检查 plist、真实资源入口、ICNS 内容 SHA、构建输入一致性、codesign 与 stapler 状态。无 Developer ID 签名或 Apple 公证；linker ad-hoc 不是开发者认证。
- 只读挂载新 DMG，检查 App、许可证、来源、安装与限制说明、应用程序快捷方式。复制到独立首次安装目录，逐文件校验并实际执行 `--check-resources`。
- 只读挂载真实旧 0.1.0 包，在独立升级目录保留旧 App 与完整合成资料备份，再放入新版。核对新旧 App、合成资料与备份原字节，执行新版资源入口。**这只证明文件替换与资源执行，不代表数据迁移或首次完整 GUI 启动。**
- 详情退出保护新增 10 项实际 `applicationShouldTerminate` 回归：标题／来源草稿、活动 field editor、真实保存中、第一／第二次写入失败、隐私隐藏及剪贴板丢弃分支。先观察真实 RED，再修复并完成上述完整原生回归。退出提示不包含材料内容；保存完成或明确处理详情后可正常退出。
- `scripts/check-site.py` 的完整 63 项交互结果属于 Task 17 原网站与旧下载包 epoch；五个网站实现文件字节未变，未重复完整运行。原外层 zsh 记录错误退出 1、checker 直接退出码未捕获的事实继续保留，不能补称 exit 0。`scripts/check-release-site.py` 对本次新包重新校验版本／静态回退／manifest、实际下载 SHA、一次真实“···”菜单发送、最终 README 桌面／手机图及 Pages 文件限制，5 项通过、退出码 0。

图标各尺寸与深浅背景已实际查看，包内 ICNS／Info.plist 核对；README 使用最终 metadata 加载后的真实 Chromium 渲染，不以旧 QA 图片替代。手机截图是浏览器模拟。Finder、应用切换器和实际挂载窗口的视觉效果为 **NOT VERIFIED**，宿主锁屏时未绕过限制。

## 追溯与发布边界

源码追溯同时保留构建时 HEAD 与 dirty 输入内容 SHA。输入覆盖全部 Sources（含未跟踪新增文件）、版本、品牌、构建／打包／检查脚本、包内说明；排除 `.DS_Store`、DMG、生成 manifest、日志和其它自引用输出。计算方法和逐文件 SHA 在输入清单中，最终提交后可重新运行 `scripts/release-tools.py source --out <新文件>` 核对 `sha256`。HEAD 或 dirty 状态可因提交变化，输入内容 SHA 应保持一致；无需为包含自身提交 ID 循环重包。

仅明确列出的产品、测试、站点、图标、最终截图与脱敏摘要建议提交；原始 `.superpowers` 日志、安全事件及历史 records 不整体发布。候选文件准备不代表 GitHub／Pages／域名发布已完成。公开 HTTPS、部署提交和线上下载 SHA 由最终发布门禁另行记录。

## 尚未验证

实体 Intel、macOS 14、多屏／独立 Spaces、全屏切换、睡眠／唤醒、App／系统重启恢复、完整中文输入法与撤销、VoiceOver、实体触控板、微信／Codex 实际接收、Safari／Firefox、实体手机软键盘／缩放、Finder／切换器、Gatekeeper、首次完整 GUI 启动与真实升级交互，均为 **NOT VERIFIED**。资源入口不会启动 AppKit，也不访问真实资料库或修改偏好；不能据此推断上述流程已通过。

[人工验收卡与合成素材](records/optimization-20261012-compatibility/manual-acceptance.md)可供后续逐项执行。性能结论仅为历史框架提交代理：200 份材料的 warm native submission p95 曾由 4175.432 ms 降至 44.050 ms；后续变更未重跑该协议，不能声称当前真实屏幕呈现延迟达标。

## 历史记录

旧 0.1.0 的 232／244 项、阶段 A 的 323 项、阶段 B 的 369 项、Task 16 的 32 项专项测试，以及 Task 17 的 381 项原生与旧包记录只代表各自源码快照。Task 17 的两次外层记录失败继续作为历史保留；本次新构建、完整测试和打包均重新捕获真实退出码。旧设计、计划与审计继续保留，其未完成清单不是本候选版的功能判断。早期深色 PDF 白页判断已撤回，不作为现行缺陷。以当前本版限制、实际包和本轮验证摘要为准。
