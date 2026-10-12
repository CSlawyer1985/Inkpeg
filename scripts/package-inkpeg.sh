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
# Only the App, Applications shortcut and helper are visible in the DMG.
resources="$stage/Inkpeg.app/Contents/Resources"
cp "$project_root/LICENSE" "$resources/LICENSE"
cp "$project_root/packaging/来源与致谢.txt" "$resources/来源与致谢.txt"
awk -v label="$architecture_label" '/^通用架构：/ { print "本包架构：" label " · 最低 macOS 14"; next } { print }' "$project_root/packaging/先读我-安装与使用.txt" > "$resources/先读我-安装与使用.txt"
cp "$project_root/docs/inkpeg/INSTALL.md" "$resources/安装教程.md"
cp "$project_root/docs/inkpeg/KNOWN-ISSUES.md" "$resources/本版限制.md"
ln -s /Applications "$stage/应用程序"
cat > "$resources/BUILD-INFO.txt" <<INFO
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
(app/'Contents/Resources/安装校验.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(stage))+'\n' for p in sorted(app.rglob('*')) if p.is_file() and p.name!='安装校验.sha256'))
CHECKSUMS
build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")"
dmg="$output/Inkpeg-$version-build$build-$architecture.dmg"
# Save Finder's background and three-icon layout in a writable image first.
rw="$work/installer-writable.dmg"
hdiutil create -srcfolder "$stage" -volname "文夹 Inkpeg $version build $build" -format UDRW "$rw"
mountpoint="$work/mounted"
mkdir "$mountpoint"
hdiutil attach -readwrite -nobrowse -mountpoint "$mountpoint" "$rw"
# This only configures the newly mounted installer window. Failure stops release.
osascript - "$mountpoint" <<'FINDER'
on run argv
    set rootPath to item 1 of argv
    tell application "Finder"
        set installerFolder to item ((POSIX file rootPath) as alias)
        open installerFolder
        tell installerFolder
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {220, 100, 940, 684}
            set viewOptions to icon view options of container window
            set icon size of viewOptions to 80
            set arrangement of viewOptions to not arranged
            set background picture of viewOptions to file "Inkpeg.app:Contents:Resources:dmg-background.png"
        end tell
        set position of item "Inkpeg.app" of installerFolder to {140, 214}
        set position of item "安装文夹.command" of installerFolder to {360, 214}
        set position of item "应用程序" of installerFolder to {580, 214}
        update installerFolder without registering applications
        delay 2
        close container window of installerFolder
    end tell
end run
FINDER
sync
hdiutil detach "$mountpoint"
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
hdiutil verify "$dmg"
cp "$resources/先读我-安装与使用.txt" "$output/先读我-安装与使用.txt"
cp "$resources/安装教程.md" "$output/安装教程.md"
cp "$resources/本版限制.md" "$output/本版限制.md"
cp "$resources/BUILD-INFO.txt" "$output/BUILD-INFO.txt"
cp "$work/bundle-inspection.json" "$output/bundle-inspection.json"
cp "$app_source/Contents/Resources/build-source.json" "$output/build-source.json"
(cd "$output" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt)
printf '%s\n' "Created $dmg" "Checksums: $output/SHA256SUMS.txt"
# Work files remain in the task's /tmp folder for inspection. No permanent
# cleanup and no changes to the user's library or Applications directory.
