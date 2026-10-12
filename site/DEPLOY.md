# 文夹 Inkpeg 产品页 · 部署说明

本目录（`site/`）是完整的静态站点：网页、动效库、宣传片和安装包都在里面，不依赖 CDN、第三方字体或后端。部署时按发布白名单上传，不包含历史下载包或工作记录，安装包 `downloads/Inkpeg-2.0.0-build4-universal.dmg` 与网页放在同一站点下。

## 上线前核对

> **2.0.0／build 4 已准备就绪（2026-10-12）**：公开预览通用包 2,482,270 字节，391 项自动回归通过，未签名／未公证。`release.json`、实际 DMG 和 SHA256SUMS 已一致；Intel 实机等未验收项见下载区限制。

以后更新版本时，先在独立副本打包验证，再同步元数据与页面。交接原文见 `../docs/inkpeg/HANDOFF-2.0.md`。

放入 `downloads/Inkpeg-2.0.0-build4-universal.dmg` 并同步元数据后：

```sh
cd site
(cd downloads && shasum -a 256 -c SHA256SUMS.txt)          # 期望：Inkpeg-2.0.0-build4-universal.dmg: OK
stat -f %z downloads/Inkpeg-2.0.0-build4-universal.dmg       # macOS；Linux 用 stat -c %s。应等于 release.json 的 sizeBytes
grep -E '"pending"|"sizeBytes"|"sha256"' downloads/release.json   # pending 一行应已删除
```

三处必须一致：DMG 实际 SHA-256 与大小、`release.json`、`SHA256SUMS.txt`。

注意：
- 下载按钮只指向本站的 `downloads/` 文件，**不要**改成私有仓库的 GitHub Release 地址（访客没有权限）。页面上的源码仓库链接保留“需授权”标注。
- `site/.gitignore` 忽略了 `downloads/*.dmg`，所以从 Git 仓库自动构建时 DMG **不会**被带上。请用“直接上传目录”的方式部署，或在构建步骤中把 DMG 复制进 `downloads/`。
- 换新安装包时，按 `site/README.md`“更新安装包”一节同步文件名、`release.json`、`SHA256SUMS.txt` 和页面文字。

## 路线一：Cloudflare Pages

**拖放上传（最简单）**
1. Cloudflare 控制台 → Workers & Pages → 创建 → Pages → “上传资产”。
2. 填项目名（例如 `inkpeg`），把准备好的发布目录拖进去，部署。
3. 根目录下的 `_headers` 会自动生效：`.dmg` 以 `application/x-apple-diskimage` 和 `Content-Disposition: attachment` 下发，`release.json`／`SHA256SUMS.txt` 只缓存 60 秒。

**命令行（wrangler）**
```sh
npm i -g wrangler          # 或 npx wrangler …
wrangler login
wrangler pages project create inkpeg --production-branch main   # 首次
wrangler pages deploy <发布目录> --project-name inkpeg --branch main
```

**单文件上限：** Cloudflare Pages 每个文件最大 **25 MiB**。2.0.0 安装包约 2.4 MiB（2,482,270 字节），最大的视频 `media/promo-1080.mp4` 约 6 MiB，远低于上限。以后安装包若超过 25 MiB，需改放 R2 等对象存储，并同步修改下载链接和 `release.json`。

## 路线二：Netlify Drop

1. 打开 <https://app.netlify.com/drop>（需登录 Netlify 账号）。
2. 把准备好的发布目录拖进页面，等待上传完成，即得到一个 `*.netlify.app` 地址；可在站点设置中绑定自己的域名。
3. Netlify 同样读取根目录 `_headers`，无需额外配置。
4. 更新时在该站点的 Deploys 页再次拖入新的 `site/` 文件夹。

## 路线三：自有服务器（nginx）

把 `site/` 上传到例如 `/var/www/inkpeg`，在站点配置中加入：

```nginx
server {
    listen 443 ssl http2;
    server_name inkpeg.example.com;          # 换成你的域名
    root /var/www/inkpeg;
    index index.html;
    charset utf-8;

    # 补充 MIME（nginx 默认 mime.types 里没有 .dmg / .vtt / .md）
    types {
        application/x-apple-diskimage dmg;
        text/vtt                      vtt;
        text/markdown                 md;
    }

    location ~* ^/downloads/.+\.dmg$ {
        default_type application/x-apple-diskimage;
        add_header Content-Disposition "attachment" always;
        add_header Cache-Control "public, max-age=3600" always;
        add_header X-Content-Type-Options "nosniff" always;
    }
    location = /downloads/release.json   { add_header Cache-Control "public, max-age=60, must-revalidate" always; }
    location = /downloads/SHA256SUMS.txt { add_header Cache-Control "public, max-age=60, must-revalidate" always; }
    location ~* ^/media/.+\.(mp4|webm)$  { add_header Cache-Control "public, max-age=604800" always; }   # 支持 Range 请求，视频可拖动进度
}
```

修改后执行 `sudo nginx -t && sudo systemctl reload nginx`。

注意：`types {}` 写在 server 内会覆盖默认 MIME 表，如果站点其他文件类型出错，改为在 `/etc/nginx/mime.types` 中追加这三行，删掉 server 里的 `types` 块。

## 上线后检查

把 `https://你的域名` 换成实际地址：

```sh
B=https://你的域名

# 1. 响应头：200、MIME、附件下载、大小
curl -sI "$B/downloads/Inkpeg-2.0.0-build4-universal.dmg" | grep -iE '^HTTP|content-type|content-disposition|content-length'
#    期望：HTTP/2 200 · content-type: application/x-apple-diskimage · content-disposition: attachment · content-length 等于 release.json 的 sizeBytes

# 2. 校验文件、说明文档、宣传片
for p in downloads/SHA256SUMS.txt downloads/release.json "downloads/%E5%AE%89%E8%A3%85%E6%95%99%E7%A8%8B.md" "downloads/%E6%9C%AC%E7%89%88%E9%99%90%E5%88%B6.md" media/promo-1080.mp4 media/promo.zh.vtt; do
  printf '%s  ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' "$B/$p"; done
#    期望：全部 200（两个中文文件名分别是“安装教程.md”和“本版限制.md”）

# 3. 下载后校验 SHA-256（macOS）
curl -sSLo /tmp/Inkpeg.dmg "$B/downloads/Inkpeg-2.0.0-build4-universal.dmg"
shasum -a 256 /tmp/Inkpeg.dmg
#    期望：与 SHA256SUMS.txt／release.json 中的 sha256 一致
#    或者：curl -sSL "$B/downloads/SHA256SUMS.txt" | sed 's#Inkpeg-2.0.0-build4-universal.dmg#/tmp/Inkpeg.dmg#' | shasum -a 256 -c
```

最后在浏览器里打开首页，点“下载 Mac 通用版”，确认按钮已启用、显示的大小与 release.json 一致，下载得到的文件 SHA-256 与页面上显示的一致。

## 本版状态提醒

2.0.0 为公开预览版，未签名／未公证。391 项回归来自本次 2.0.0 代码；Intel 实机、旧系统、新机 Gatekeeper、微信／Codex 接收等边界未验收。后续版本应重新构建与核验，不沿用本次结论。

本次 Git 提交使用 `[CF-Pages-Skip]` 前缀，避免仓库自动部署缺少新 DMG 的目录；该标记只跳过 Cloudflare Pages 构建。随后直接部署含已校验 DMG 的白名单目录，不跳过应用 CI。旧文件在仓库及备份中保留。
