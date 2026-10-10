# 0.1.0 内部测试版验证摘要

2026-10-10。本版是 Apple Silicon 内部测试快照，尚未完成正式 1.0 或 Apple 签名公证验收。

| 核验 | 命令或实际操作 | 结果 |
| --- | --- | --- |
| 完整回归 | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`，使用独立 scratch path | InkpegCore 137＋InkpegApp 95＝232；0 failures。 |
| 发行构建 | `scripts/build-inkpeg.sh --configuration release --no-sign` | Release 构建与 en／es／zh-Hans 资源校验通过。 |
| 原生记事 | 中文纯文字 Command-V、普通 Return 换行与草稿重开 | 实际原生界面验证通过；完整中文输入法候选流程未实测。 |
| 清理流程 | 隔离合成资料：预览、取消、确认、再次预览 | 取消文件全不变；确认仅移动两项 eligible 副本，废纸篓目的地核验通过；原件、绳上资料与未完成草稿保留。 |
| 故障恢复 | 状态第二次写失败、Trash 移动后异常／目的地未知、清理记录更新中断、重启重试 | 对应回归通过；无法核验时不宣称成功。 |
| 旧图像标注草稿恢复 | 更新版本后显式恢复旧草稿，再保存；检查原件、历史版本与草稿 | 新增回归先复现旧基准与 invalidEdit，修复后通过；真实系统 Markup 恢复交互本轮未实测。 |
| DMG | `scripts/package-inkpeg.sh --app <verified-app>`、`hdiutil verify`、SHA256 | UDZO 镜像与校验值通过；包内许可证及来源与原文一致。 |
| 复制与启动 | 只读挂载，复制到隔离安装目录，逐文件 SHA256 与 `--check-resources`，独立开发数据根启动 | 文件一致，资源正确，arm64，原生运行及接收工作流初始化通过。 |
| 代码及许可 | 独立只读审查、`git diff --check`、许可／上游 README 哈希 | 无已确认必须修正问题，原许可与上游原文保留。 |

本机环境：macOS 26.6.2，arm64。测试素材由验证流程生成，不使用真实用户资料作清理测试。

未验证：新机首次下载 Gatekeeper、真实覆盖升级、macOS 14／15、Intel、完整多屏、完整中文输入法交互、所有跨应用拖放与网络观察。微信／Codex 直接拖入、满绳横向滚动、事项／历史、双栏对照和完整隐私开关仍未完成，见 [本版限制](KNOWN-ISSUES.md)。

本机 linker ad hoc 签名不是 Developer ID。安装说明由用户按 Apple 官方流程自行确认，本包不自动修改系统安全设置或下载隔离标记。
