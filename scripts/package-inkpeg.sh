#!/bin/bash
# Assemble a preview DMG; the included helper runs only on explicit user action.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_source=""
output=""
while (($#)); do
  case "$1" in
    --app) app_source="${2:?app path required}"; shift 2 ;;
    --output) output="${2:?new output directory required}"; shift 2 ;;
    --help)
      printf '%s\n' 'Usage: scripts/package-inkpeg.sh [--app /path/to/Inkpeg.app] [--output /path/to/new-directory]'
      exit 0 ;;
    *) printf '%s\n' 'Unknown packaging argument' >&2; exit 2 ;;
  esac
done
if [[ -n "$output" && ( -e "$output" || -L "$output" ) ]]; then
  printf '%s\n' 'Output already exists; choose a new directory.' >&2; exit 2
fi
work="$(mktemp -d /tmp/inkpeg-installer.XXXXXX)"
if [[ -z "$app_source" ]]; then
  "$project_root/scripts/build-inkpeg.sh" --configuration release --no-sign | tee "$work/build.log"
  app_source="$(tail -n 1 "$work/build.log")"
fi
plist="$app_source/Contents/Info.plist"
binary="$app_source/Contents/MacOS/Inkpeg"
[[ -d "$app_source" && ! -L "$app_source" && -f "$plist" && -x "$binary" ]] || {
  printf '%s\n' 'Expected a complete Inkpeg app bundle.' >&2; exit 2;
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" == 'local.inkpeg.Inkpeg' ]] || {
  printf '%s\n' 'Unexpected bundle identifier.' >&2; exit 2;
}
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
arch_list="$(lipo -archs "$binary" | tr ' ' '\n' | sort | tr '\n' ' ')"
case "$arch_list" in
  'arm64 x86_64 ') architecture=universal; architecture_label='Apple Silicon（M 系列）＋Intel（x86_64）通用架构' ;;
  'arm64 ') architecture=arm64; architecture_label='Apple Silicon（M 系列），仅 arm64' ;;
  'x86_64 ') architecture=x86_64; architecture_label='Intel（x86_64），仅 x86_64' ;;
  *) printf '%s\n' 'Expected arm64, x86_64, or both; unexpected architecture set.' >&2; exit 2 ;;
esac
python3 "$project_root/scripts/release-tools.py" inspect --app "$app_source" --out "$work/bundle-inspection.json"
"$binary" --check-resources
stamp="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)"
[[ -n "$output" ]] || output="$project_root/.build/InkpegReleases/$version-preview-$stamp"
mkdir -p "$(dirname "$output")"
# Exclusive mkdir: a concurrent run cannot overwrite a completed release.
mkdir "$output"
output="$(cd "$output" && pwd)"
stage="$work/stage"
mkdir "$stage"
ditto --norsrc --noextattr "$app_source" "$stage/Inkpeg.app"
cp "$project_root/packaging/安装文夹.command" "$stage/安装文夹.command"
chmod +x "$stage/安装文夹.command"
cp "$project_root/LICENSE" "$stage/LICENSE"
cp "$project_root/packaging/来源与致谢.txt" "$stage/来源与致谢.txt"
awk -v label="$architecture_label" '/^通用架构：/ { print "本包架构：" label " · 最低 macOS 14"; next } { print }' "$project_root/packaging/先读我-安装与使用.txt" > "$stage/先读我-安装与使用.txt"
cp "$project_root/docs/inkpeg/INSTALL.md" "$stage/安装教程.md"
cp "$project_root/docs/inkpeg/KNOWN-ISSUES.md" "$stage/本版限制.md"
# Keep attribution with the app even when it is copied out of the disk image.
cp "$project_root/LICENSE" "$stage/Inkpeg.app/Contents/Resources/LICENSE"
cp "$project_root/packaging/来源与致谢.txt" "$stage/Inkpeg.app/Contents/Resources/来源与致谢.txt"
ln -s /Applications "$stage/应用程序"
cat > "$stage/BUILD-INFO.txt" <<INFO
Inkpeg $version preview
Packaged at: $stamp (Asia/Shanghai)
Architecture: $architecture ($arch_list)
Minimum deployment target: macOS 14
No Developer ID signature or Apple notarization supplied by this packaging step.
Linker ad hoc signature is not developer identity verification.
This is a public preview. The installation helper only prepares its installed Inkpeg copy on explicit confirmation.
INFO
"$stage/Inkpeg.app/Contents/MacOS/Inkpeg" --check-resources
python3 - "$stage" <<'CHECKSUMS'
import hashlib,pathlib,sys
stage=pathlib.Path(sys.argv[1]);app=stage/'Inkpeg.app'
(stage/'安装校验.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(stage))+'\n' for p in sorted(app.rglob('*')) if p.is_file()))
CHECKSUMS
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")"
dmg="$output/Inkpeg-$version-build$build-$architecture.dmg"
hdiutil create -srcfolder "$stage" -volname "文夹 Inkpeg $version 预览版" -format UDZO -imagekey zlib-level=9 "$dmg"
hdiutil verify "$dmg"
cp "$stage/先读我-安装与使用.txt" "$output/先读我-安装与使用.txt"
cp "$stage/安装教程.md" "$output/安装教程.md"
cp "$stage/本版限制.md" "$output/本版限制.md"
cp "$stage/BUILD-INFO.txt" "$output/BUILD-INFO.txt"
cp "$work/bundle-inspection.json" "$output/bundle-inspection.json"
cp "$app_source/Contents/Resources/build-source.json" "$output/build-source.json"
(cd "$output" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt)
printf '%s\n' "Created $dmg" "Checksums: $output/SHA256SUMS.txt"
# Work files remain in the task's /tmp folder for inspection. No permanent
# cleanup and no changes to the user's library or Applications directory.
