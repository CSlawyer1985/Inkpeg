#!/bin/bash
# Inkpeg installation helper. Run explicitly; never changes global security settings.
set -euo pipefail
package_dir="$(cd "$(dirname "$0")" && pwd)"
destination=""
launch_app=true
confirm_install=false
while (($#)); do
  case "$1" in
    --destination) destination="${2:?需要安装目录}"; shift 2 ;;
    --no-launch) launch_app=false; shift ;;
    --confirm) confirm_install=true; shift ;;
    --help) printf '%s\n' '安装文夹.command [--destination 安装目录] [--no-launch] [--confirm]'; exit 0 ;;
    *) printf '%s\n' '无法识别参数。' >&2; exit 2 ;;
  esac
done
fail() { printf '\n安装未完成：%s\n' "$1" >&2; exit 1; }
source_app="$package_dir/Inkpeg.app"
[[ -d "$source_app" && ! -L "$source_app" && -x "$source_app/Contents/MacOS/Inkpeg" ]] || fail '请在安装包窗口中运行此助手。'
manifest="$source_app/Contents/Resources/安装校验.sha256"
[[ -s "$manifest" && ! -L "$manifest" ]] || fail '安装校验文件缺失，请重新下载同版安装包。'
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" == 'local.inkpeg.Inkpeg' ]] || fail '应用名称校验不符。'
# Every checksum must refer to a regular, non-symlink file within this app.
while IFS= read -r line || [[ -n "$line" ]]; do
  relative="${line#*  }"
  [[ "$relative" == Inkpeg.app/Contents/* && "$relative" != *'/../'* && -f "$package_dir/$relative" && ! -L "$package_dir/$relative" ]] || fail '安装校验路径无效。'
done < "$manifest"
[[ -z "$(/usr/bin/find "$source_app" -type l -print)" ]] || fail '安装包包含异常链接，请重新下载。'
(cd "$package_dir" && /usr/bin/shasum -a 256 -c "$manifest") >/dev/null || fail '应用文件不完整，请重新下载。'
if [[ -z "$destination" ]]; then
  if [[ -w /Applications ]]; then destination=/Applications
  else destination="$HOME/Applications"; /bin/mkdir -p "$destination"
  fi
fi
[[ "$destination" == /* && -d "$destination" && ! -L "$destination" && -w "$destination" ]] || fail '安装目录不可写，请选择自己的应用程序目录。'
destination="$(cd "$destination" && pwd)"
target="$destination/Inkpeg.app"
[[ ! -L "$target" ]] || fail '目标位置是链接，未修改。请先检查现有应用。'
if /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Inkpeg >/dev/null; then fail '请先从文夹菜单退出旧版，再运行安装助手。'; fi
printf '%s\n' '文夹 Inkpeg · 安装并首次打开' "安装到：$destination" '本助手仅为这一份文夹应用准备首次打开，不更改全局安全设置。' '如有旧版，将保留一份旧 App；资料库保持不变。'
if $confirm_install; then
  read -r -p '按回车开始，输入 q 取消：' answer || exit 1
  [[ "$answer" != q && "$answer" != Q ]] || exit 0
fi
work="$(/usr/bin/mktemp -d /tmp/inkpeg-install.XXXXXX)"
lock="$destination/.Inkpeg-install-lock"
/bin/mkdir "$lock" 2>/dev/null || fail '另一个安装过程尚未结束，请稍后再试。'
# Keep our empty lock in the temporary evidence folder; no permanent deletion.
trap '/bin/mv "$lock" "$work/completed-lock" 2>/dev/null || :' EXIT
printf '\n1/3 正在复制文夹…\n'
/usr/bin/ditto --norsrc --noextattr "$source_app" "$work/Inkpeg.app"
backup=""
if [[ -e "$target" ]]; then
  backup="$destination/Inkpeg-旧版-$(/bin/date +%Y%m%d-%H%M%S)-$$.app"
  [[ ! -e "$backup" ]] || fail '旧版保留位置冲突，未覆盖。'
  /bin/mv "$target" "$backup"
fi
if ! /bin/mv "$work/Inkpeg.app" "$target"; then
  if [[ -n "$backup" && ! -e "$target" ]]; then /bin/mv "$backup" "$target"; fi
  fail '复制失败，旧版与资料库已保留。'
fi
printf '2/3 正在准备首次打开…\n'
while IFS= read -r -d '' item; do
  if /usr/bin/xattr -p com.apple.quarantine "$item" >/dev/null 2>&1; then /usr/bin/xattr -d com.apple.quarantine "$item"; fi
done < <(/usr/bin/find "$target" -print0)
printf '3/3 正在启动…\n'
if $launch_app; then /usr/bin/open "$target"; fi
printf '\n安装完成。鼠标移到屏幕顶部，或按 Control＋Option＋T 打开文夹。\n'
if [[ -n "$backup" ]]; then printf '旧 App 已保留：%s\n' "$backup"; fi
printf '%s\n' '可以关闭此终端窗口，开始使用文夹。'
