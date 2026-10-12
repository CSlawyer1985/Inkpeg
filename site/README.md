# 文夹 Inkpeg 产品介绍页

静态产品页，以可操作的桌面与绳子演示材料挂入、复制、记事、满绳横向浏览、拖出、设置与清理预览。没有业务后端，不读取用户剪贴板、文件或原生 App；复制动作只在访客明确点击后请求浏览器写入。页面中的桌面、菜单栏和卡片均为 HTML／SVG 示意重绘，不是原生截图。

## 目录

- `index.html`：中文介绍、交互桌面、痛点故事、功能拼贴、本机存储、下载、安装及 FAQ。
- `styles.css` / `app.js`：站点排版（亮／暗主题、响应式）、交互桌面状态与滚动叙事。
- `inkdesk.css` / `inkdesk.js`：InkDesk 示意界面组件（菜单栏、绳子、夹子、卡片、记事、设置面板），几何参数取自 `LineView.swift`／`PeggedView.swift`；站点、README 配图与宣传片共用。
- `assets/`：本项目原创标识（朱红夹子夹住纸卡）与亮／暗桌面壁纸 SVG，不使用上游图片。
- `vendor/`：固定版本 GSAP 3.15.0 / ScrollTrigger、原始版权头、官方许可和来源校验。
- `downloads/`：通用 DMG、SHA256、版本元数据、安装教程和限制。大安装包不纳入 Git，部署包会包含实际文件。
- `media/`：宣传片网页版编码（1080p MP4／WebM、720p MP4、静音预告片）、封面图和中文字幕 `promo.zh.vtt`。
- `film.js`：宣传片区块（进入视口才加载的静音预告片、点击后有声播放的灯箱、章节跳转）。
- `_headers` / `DEPLOY.md`：Cloudflare Pages／Netlify 响应头与三种部署方式。
- `LICENSE.txt`：Inkpeg / Tendedero 的 MIT 许可；不覆盖第三方 GSAP，其许可单独保留。

## 本地预览

在项目根运行：

```sh
python3 -m http.server 8767 --bind 127.0.0.1 --directory site
```

打开 `http://127.0.0.1:8767/`。正式域名：<https://inkpeg.chenshi.ai/>，部署见 `DEPLOY.md`。也可用 `?state=received`、`?state=copy`、`?state=menu`、`?state=note`、`?state=overflow`、`?state=settings`、`?state=cleanup`、`?state=intake`、`?state=hidden`、`?state=dropping` 直接查看关键状态，`?theme=dark|light` 指定主题，`?noreveal` 关闭进入视口淡入。页面资源全在本地，不依赖 CDN 或第三方字体。用 HTTP 预览；直接双击 HTML 的浏览器文件协议会限制版本元数据读取。`python3 -m http.server` 不支持 Range 请求，宣传片章节跳转在它下面会从头播放；正式静态托管（Cloudflare／Netlify／nginx）均支持。

系统开启“减弱动态效果”时，卡片直接就位、不摆动，自动演示与滚动叙事改为静态。交互桌面支持键盘：聚焦桌面图标按回车挂入，卡片上左右方向键浏览，Esc 收起记事。

## 核验

项目根运行（测试环境需已安装 Python Playwright / Chromium）：

```sh
python3 scripts/check-site.py --url http://127.0.0.1:8767 --out /tmp/inkpeg-site-check
```

测试真实点击、拖动、记事、完整引导、手机等价操作、减弱动画、六种视口、下载及实际 SHA，不使用真实工作材料或外部 App。`check-site.py` 已按 当前桌面更新，含取消拖动、明暗主题、触屏、宣传片、占位下载阻断与无 JS 下载回归。宣传片章节检查需用 `python3 marketing/tools/range_server.py site 8767` 预览。

## 更新安装包

1. 用 `scripts/build-inkpeg.sh --configuration release --no-sign` 构建；默认 universal。
2. 用 `scripts/package-inkpeg.sh --app <已验证App> --output <新的输出目录>` 生成新包。
3. 核验 DMG 架构／最低系统／资源／内容／SHA，复制成 `downloads/Inkpeg-2.0.0-build3-universal.dmg`。
4. 同步 `release.json` 的大小／SHA／版本／实测状态和 `SHA256SUMS.txt`，删除 `release.json` 中的 `pending`，同步两份说明。占位期间页面下载按钮自动停用。
5. 重新执行网页下载测试，确保按钮实际返回这一包。升级版本时一起修改页面显示、文件名和链接，不能只改文案。

当前发行 2.0.0／build 3，391 项原生回归与 7 项安装助手回归通过。DMG 内含实际 App 图标、`安装文夹.command` 和简明说明。网站仅显示必要操作提示；制作过程说明保留在此文件和媒体来源清单。
