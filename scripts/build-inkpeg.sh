#!/bin/bash
set -euo pipefail
configuration=debug
while (($#)); do
  case "$1" in
    --configuration) configuration="${2:?configuration required}"; shift 2 ;;
    --no-sign) shift ;;
    *) printf '%s\n' 'Unknown packaging argument' >&2; exit 2 ;;
  esac
done
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
project_root="$(cd "$(dirname "$0")/.." && pwd)"
# Temporary output avoids Finder metadata injected into Documents build bundles.
build_root="$(mktemp -d /tmp/inkpeg-build.XXXXXX)"
package_root="$(mktemp -d /tmp/inkpeg-package.XXXXXX)"
cd "$project_root"
swift build --scratch-path "$build_root" -c "$configuration" --product Inkpeg
binary_root="$(swift build --scratch-path "$build_root" -c "$configuration" --show-bin-path)"
app="$package_root/Inkpeg.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_root/Inkpeg" "$app/Contents/MacOS/Inkpeg"
cp -R "$binary_root/Inkpeg_InkpegCore.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.inkpeg.Inkpeg</string>
<key>CFBundleExecutable</key><string>Inkpeg</string>
<key>CFBundleName</key><string>Inkpeg</string>
<key>CFBundleDisplayName</key><string>文夹</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
"$app/Contents/MacOS/Inkpeg" --check-resources
printf '%s\n' "$app"
