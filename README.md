# Inkpeg · 文夹

把截图、文字、图片、PDF 和普通文件挂在屏幕上方，随手查看、复制和继续记事。使用 Swift、AppKit 与 SwiftUI 构建，资料保存在本机。

**当前版本：0.1.0 内部测试版，2026-10-10。** 新版设置面板、记事输入／粘贴和存储清理已实现，完整自动回归 232 项通过。尚未完成正式 1.0 验收、Developer ID 签名和 Apple 公证。

## 下载与安装

内部测试安装包发布在 [Inkpeg 私有仓库的 Releases](https://github.com/CSlawyer1985/Inkpeg/releases/tag/v0.1.0-internal.20261010)，需使用有权限的 GitHub 账号登录。当前没有公开正式下载地址。打开收到的 `文夹-Inkpeg-0.1.0-internal-…-arm64.dmg`，先阅读“先读我-安装与使用.txt”，再把 `Inkpeg.app` 拖入“应用程序”。

- [完整安装、升级、卸载和未签名首次打开教程](docs/inkpeg/INSTALL.md)
- [功能与使用说明](README.zh-CN.md)
- [本版限制与发布状态](docs/inkpeg/KNOWN-ISSUES.md)

本次安装包仅含 **Apple Silicon（M 系列）** 架构。工程最低系统为 macOS 14；本机验收在 macOS 26.6.2，macOS 14／15 的新机首次安装尚待测试。Intel 版未构建，不能宣传支持。

## 当前可用

- 拖入图片、文字、PDF 或本地普通文件，或从绳子／回形针菜单选择“粘贴挂入”“挂入文件”。保存独立副本，原件保留。
- 新工作区默认手动挂入；设置中可选择剪贴板自动接收类型和截图目录监听。
- 点击绳上的小红段新建或恢复记事。支持 `⌘V`、本地草稿自动保存，以 `⌘Return` 或“挂上去”发布卡片。
- 普通材料单击复制；记事卡单击继续编辑。右键查看来源／详情、打开或编辑副本、取下卡片。
- 设置中的“存储”页查看占用与资料库位置，预览后清理已取下且未固定的材料及超过 24 小时的临时导出。
- 清理移入系统废纸篓，保护原件、绳上／固定／待审资料和编辑／恢复草稿。真正释放磁盘空间需要用户自行清空废纸篓。

微信／Codex 输入框的直接拖入粘贴兼容、满绳后的触控板横向滚动、事项／历史、双栏对照和完整隐私开关仍待完成；请先用“复制 → 目标输入框 ⌘V”。满绳时旧的未固定卡目前会被取下，副本继续保留；清理前务必核对预览清单。[详细限制](docs/inkpeg/KNOWN-ISSUES.md)。

## 数据与隐私

默认资料库：`~/Library/Application Support/Inkpeg/`。包含材料与版本、导出临时副本、草稿、恢复事务、清理记录及设置状态。升级只更换应用，保留这个资料库。不要直接修改其中的文件。

不需要账号或云端模型，当前业务流程在本机运行。剪贴板自动接收默认关闭；开启后会接收所选类型。工程没有应用联网功能，但尚未完成运行时网络观察，不将源码检查当作完整隐私认证。

## 构建与核验

需 macOS 和包含 Swift 工具链的 Xcode；本项目无第三方包依赖。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-inkpeg.sh --configuration release --no-sign
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/package-inkpeg.sh
```

`package-inkpeg.sh` 在新的 `.build/InkpegReleases/` 子目录生成内部测试 DMG、SHA-256 和安装说明；不覆盖旧包，不更改系统安全设置或执行安装。也可用 `--app /path/to/Inkpeg.app` 封装已验证的构建，用 `--output /path/to/new-directory` 指定一个尚不存在的输出目录。

| 目录 | 用途 |
| --- | --- |
| `Sources/InkpegCore/` | 托管材料、版本、草稿、接收与清理核心。 |
| `Sources/Tendedero/` | 沿用上游源码路径的原生界面与系统适配；产品名称为 Inkpeg。 |
| `Tests/` | 核心及原生应用回归测试。 |
| `scripts/` | Inkpeg 构建与打包脚本；上游脚本保留为参考。 |
| `packaging/` | 随安装包分发的入门指南与来源声明。 |
| `docs/inkpeg/` | 设计、使用、限制与验收记录；内部记录不整体用于公开分发。 |
| `.build/` | 构建、试用包、安装包和备份，不纳入 Git。 |

## 来源、致谢与许可

感谢 Alejandro Buján 开源 [Tendedero](https://github.com/alejandrobujan/tendedero)。Inkpeg 基于其固定提交 `3c866d94d25ee9d1e008aecd9a78a4e9b2bf06a4` 改造，保留原作者版权及完整 [MIT 许可证](LICENSE)，新增代码沿用 MIT。

改版采用独立名称，不使用上游图标或 `docs/` 图片作为 Inkpeg 的分发资产，不暗示原作者背书。上游说明原文保留在 [README.upstream.md](README.upstream.md)，其中的版本、下载链接和操作说明属于上游项目，并非文夹的当前功能承诺。

作者主页：[chenshi.ai](https://chenshi.ai)。
