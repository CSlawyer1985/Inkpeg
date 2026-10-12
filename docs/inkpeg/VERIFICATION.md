# 2.0.0／build 3 验证

2026-10-12，针对当前最新源码重新执行完整测试、arm64／x86_64 Release 构建与打包。官网、包内版本与仓库的版本来源统一为 `packaging/release-version.json`。

## COMMAND + OUTPUT + RESULT

| 命令／操作 | 输出 | 结果 |
| --- | --- | --- |
| `scripts/verify-inkpeg.sh <新目录>` | Core 181＋App 210，391 tests、0 failures；两架构构建 exit 0；DMG verify VALID | PASS |
| `python3 scripts/test-release.py` | 4 tests，OK | PASS |
| `python3 scripts/test-installer.py` | 7 tests，OK；安装、取消、旧 App 保留、错误 payload／id／链接拒绝、仅目标副本隔离属性处理 | PASS |
| `scripts/release-tools.py site --app <实际App> --dmg <实际DMG>` | 2.0.0／build 3；2,482,800 bytes；版本、ICNS、资源、源输入 SHA、两个二进制 slice 与最低系统一致 | PASS |
| 只读挂载实际 DMG；逐文件 SHA 校验；运行包内助手至隔离目录 | 所有文件 OK；安装完成；`Inkpeg resources OK: en, es, zh-Hans` | PASS |
| `python3 scripts/check-site.py --url <Range服务器> --out <记录>` | 28 checks passed，包括实际拖动／取消、记事、清理、14 视口、触屏、视频音频／章节、完整下载、无 JS 回退 | PASS |
| `python3 scripts/check-release-site.py --url <Range服务器> --out <记录>` | 5 checks passed；发行元数据、静态下载、简明安装流程、桌面／手机安装区、Pages 文件限制 | PASS |

安装包 SHA-256：`001b58cfd41afc2b415ad73cc3cdd26ca5e64cc31ae165ed2d50c97e84fe0d2f`。

[发行元数据](../../site/downloads/release.json)、[逐文件构建输入](../../site/downloads/build-source.json)和[公开验证摘要](../../site/downloads/verification.json)记录可追溯证据。原始日志留在本机发布备份目录，不推送私密路径或历史工作记录。

## 验证边界

安装助手由用户显式运行并确认，未修改全局安全设置，也未接触真实应用程序目录或用户资料库。隔离测试不等于全新机器 Gatekeeper 界面验收。尚无 Developer ID 签名或 Apple 公证；linker ad-hoc 签名不是开发者身份认证。

未完成 Intel 实机、macOS 14 实机、多屏／Spaces、完整输入法与撤销、VoiceOver、微信／Codex 实际接收、Safari／Firefox 或实体手机键盘验收。网站与 README 的画面来自真实浏览器组件渲染、项目宣传片片段，非原生 App 截图。旧完整网页图片保留为历史资产，README 不再引用。

## 追溯与历史

构建记录的 HEAD 是打包前基线，dirty 输入 SHA 覆盖 Sources、品牌、版本、构建及包内说明；提交后 HEAD 可变化，输入 SHA 应保持一致。原生 Sources 与 Tests 沿用最新 GitHub 基线，本次修改集中于发行、图标、安装助手、网站和文档。旧 0.2.0／build 2 验证摘要与站点文件在本机备份中保留，旧原生功能验收结论不扩大到实体兼容矩阵。

网站是已经发布设计的整合，原网站菜单交互契约改为当前“单击复制／右键”，测试相应更新；完整新网站真实行为重新验证，保留取消拖动、下载等待、草稿与缩放回归。许可证原文和原作者版权未变。
