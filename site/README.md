# 文夹 Inkpeg 产品介绍页

静态产品页，以可操作桌面演示挂入、记事、横向浏览与拖出。无业务后端，不读取用户剪贴板或本机文件，不调用原生 App。复制仅在访客点击后请求浏览器写入。

## 目录与本地核验

`index.html`、`install.html` 为介绍及安装页；`styles.css`、`app.js`、`demo-state.js` 提供交互；`assets/` 为自有品牌与山峦；`vendor/` 保留 GSAP 的许可和来源。`downloads/` 随发布源包含本次已核验 DMG、SHA、版本、构建输入清单和脱敏验证摘要。

```sh
python3 -m http.server 8768 --bind 127.0.0.1 --directory site
python3 scripts/check-site.py --url http://127.0.0.1:8768 --out /tmp/inkpeg-site-check
```

从项目根执行，浏览器检查需本机已有 Python Playwright / Chromium。不自动安装依赖。

## 版本与下载

应用版本源仅为 `packaging/release-version.json`。构建与包核验后，`scripts/release-tools.py site --app <本次已核验App> --dmg <本次DMG>` 写入实际下载及既有 `downloads/release.json`，不凭参数声明架构或签名通过。网站消费该 manifest；静态回退文字也需通过一致性核验。

当前 0.2.0／build 2 预览包包含实际检查的 arm64、x86_64 slice，最低 macOS 14.0。无 Developer ID 签名或公证。Intel、macOS 14 实机、Gatekeeper 与首次完整安装仍未验收。公开摘要 `downloads/verification.json` 和 `downloads/build-source.json` 与包一起发布，不依赖私有仓库或本机日志链接。

## GitHub → Cloudflare Pages

发布源为 GitHub `main`，静态输出目录 `site`，无需构建命令；已连接 Cloudflare Pages，生产环境自动部署已启用。`dc5139ad2b499a006768eb5e0165cd4ddb1b3dc9` 已部署，`https://inkpeg.chenshi.ai/` 网站及预览版 DMG 下载可通过 HTTPS 访问。canonical、Open Graph URL 和 sitemap 均指向该域名。

仅本次 `downloads/Inkpeg-0.2.0-build2-universal.dmg` 解除忽略并纳入明确提交清单；旧 DMG 不批量提交。仓库保持私有，GitHub 源码链接需要权限；Pages 公开静态文件使用独立可读的验证摘要。

发布检查：单文件不超过 25 MiB，总文件数不超过 20,000（[Pages 官方限制](https://developers.cloudflare.com/pages/platform/limits/)）；确认实际部署提交、HTTP、交互、manifest 与下载 SHA／大小。不得发布原始 `.superpowers` 日志、安全事件或历史 records 整目录。网页触摸模拟不替代实体手机，演示接收不替代微信／Codex 实际输入。
