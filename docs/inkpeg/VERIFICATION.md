# 2.0.0／build 5 验证

2026-10-12，版本来源为 `packaging/release-version.json`。本版加入纯产品示例和实际 Finder 安装背景，并同步官网“仍要打开”步骤。

## COMMAND + OUTPUT + RESULT

| 命令／操作 | 输出 | 结果 |
| --- | --- | --- |
| `swift test --scratch-path <独立目录>` | Core 190＋App 210，400 tests、0 failures | PASS |
| `python3 scripts/test-release.py` | 4 tests，OK | PASS |
| `python3 scripts/test-installer.py` | 11 tests，OK；默认安装、确认／取消、旧 App 保留、错误 payload／id／链接拒绝、仅目标副本隔离属性处理 | PASS |
| `scripts/build-inkpeg.sh --configuration release --architectures universal --no-sign` | 两架构独立 Release 构建 exit 0；资源和输入 SHA 一致 | PASS |
| `scripts/package-inkpeg.sh --app <实际App> --output <新目录>` | 最终 DMG verify VALID；5,159,783 bytes | PASS |
| `scripts/release-tools.py site --app <实际App> --dmg <实际DMG>` | 2.0.0／build 5；ICNS、三份示例、两个二进制 slice、macOS 14 最低系统和源指纹一致 | PASS |
| 最终 DMG 只读挂载；逐文件 SHA 校验；运行助手至隔离目录 | 3 个可见入口；全部 20 个 App 文件校验通过；安装与资源检查 exit 0 | PASS |
| 在 Finder 打开最终 DMG 并截图 | 实际显示 Logo、3 个图标、隐私与安全性／仍要打开／打开；背景和文字无遮挡 | PASS |
| 实际 App 使用独立开发资料根首次启动、再启动 | 每次持续运行 7 秒；均只有记事／图片／PDF 三份示例，自动接收及读取已有剪贴板均关闭 | PASS |
| `python3 scripts/check-site.py --url <Range服务器> --out <记录>` | 28 checks，包括实际拖动／取消、记事、清理、14 视口、触屏、视频音频／章节、完整下载及无 JS 回退 | PASS |
| `python3 scripts/check-release-site.py --url <Range服务器> --out <记录>` | 5 checks：版本、真实下载、系统允许步骤、可选命令、桌面／手机及 Pages 文件限制 | PASS |

安装包 SHA-256：`11ba28d7f45804838c4fd7b2ac811363c418ec209589187f9f567c66a6c8a34f`。

[发行元数据](../../site/downloads/release.json)、[逐文件构建输入](../../site/downloads/build-source.json)和[公开验证摘要](../../site/downloads/verification.json)提供追溯。原始日志与失败候选包保留在本机记录目录，未发布。

## 首次示例与隐私回归

9 项 Starter 专项覆盖新根三种材料、旧目录保护、取下后不重挂、损坏 payload、链接、私密来源路径和模板缺失。新增接收偏好联动用例先复现失败，再修复通过。

初始候选预放 `state.json` 后，旧库迁移规则会开启自动接收。实际启动和独立审查发现此问题；最终模板额外携带经校验的关闭设置，不改变旧库迁移行为。独立 Reviewer 重跑 9 项，并额外验证开启任一接收开关的模板会在新根创建前被拒绝，无未关闭 Findings。

只在根目录不存在时原子发布完整示例。任何已有目录（包括空目录）均保留；移除或取下示例后不重加。样本只来自产品介绍、自己的宣传图及官网下载网页，不含用户历史业务材料、本地来源路径或书签。

## 验证边界

Finder 背景截图是真实安装包窗口；README 的其他交互图来自网站组件和宣传片，非原生应用功能截图。隔离安装和本机启动不等于全新机器 Gatekeeper 界面验收。没有 Developer ID 签名／Apple 公证；linker ad-hoc 签名不是开发者身份认证。

Intel 实机、macOS 14 实机、多屏／Spaces、完整输入法与撤销、VoiceOver、微信／Codex 实际接收、Safari／Firefox、实体手机及完整 GUI 升级仍为 NOT VERIFIED。未修改全局系统安全设置。

## 构建追溯

完整验证入口先运行原生测试和构建；Finder 背景关联对象写法在实际打包时失败，参照 MemoBall 显式视图选项修正后重建。随后实际首启暴露接收设置问题，补回归、重新全量测试、重建两种架构并重新打包；只有最终产物发布。

记录的 HEAD 是提交前基线；输入 SHA 覆盖全部 Sources、品牌、产品示例、版本、构建与包内说明，提交后 HEAD 可变，输入 SHA 必须保持一致。许可证、原作者版权、资料库 schema 和旧客户库迁移行为未变。
