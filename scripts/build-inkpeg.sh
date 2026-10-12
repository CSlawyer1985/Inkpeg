#!/bin/bash
set -euo pipefail
configuration=debug
architectures=universal
while (($#)); do
  case "$1" in
    --configuration) configuration="${2:?configuration required}"; shift 2 ;;
    --architectures) architectures="${2:?architectures required}"; shift 2 ;;
    --no-sign) shift ;;
    --help) printf '%s\n' 'Usage: scripts/build-inkpeg.sh [--configuration debug|release] [--architectures universal|arm64|x86_64] [--no-sign]'; exit 0 ;;
    *) printf '%s\n' 'Unknown packaging argument' >&2; exit 2 ;;
  esac
done
case "$configuration" in debug|release) ;; *) printf '%s\n' 'Expected configuration debug or release.' >&2; exit 2 ;; esac
case "$architectures" in universal) slices='arm64 x86_64' ;; arm64|x86_64) slices="$architectures" ;; *) printf '%s\n' 'Expected architectures universal, arm64, or x86_64.' >&2; exit 2 ;; esac
project_root="$(cd "$(dirname "$0")/.." && pwd)"
# Temporary output avoids Finder metadata injected into Documents build bundles.
build_root="$(mktemp -d /tmp/inkpeg-build.XXXXXX)"
package_root="$(mktemp -d /tmp/inkpeg-package.XXXXXX)"
cd "$project_root"
app="$package_root/Inkpeg.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
python3 scripts/release-tools.py source --out "$package_root/build-source.json"
for slice in $slices; do
  minimum_macos="$(python3 -c 'import json; print(json.load(open("packaging/release-version.json"))["minimumMacOS"])')"
  triple="$slice-apple-macosx$minimum_macos"
  scratch="$build_root/$slice"
  swift build --scratch-path "$scratch" -c "$configuration" --triple "$triple" --product Inkpeg
  binary_root="$(swift build --scratch-path "$scratch" -c "$configuration" --triple "$triple" --show-bin-path)"
  actual_slice="$(lipo -archs "$binary_root/Inkpeg")"
  [[ "$actual_slice" == "$slice" ]] || { printf 'Expected %s; built %s.\n' "$slice" "$actual_slice" >&2; exit 2; }
  cp "$binary_root/Inkpeg" "$package_root/Inkpeg-$slice"
  resources="$app/Contents/Resources/Inkpeg_InkpegCore.bundle"
  if [[ -d "$resources" ]]; then
    diff -qr "$resources" "$binary_root/Inkpeg_InkpegCore.bundle"
  else
    cp -R "$binary_root/Inkpeg_InkpegCore.bundle" "$resources"
  fi
done
if [[ "$architectures" == universal ]]; then
  lipo -create "$package_root/Inkpeg-arm64" "$package_root/Inkpeg-x86_64" -output "$app/Contents/MacOS/Inkpeg"
  actual_slices="$(lipo -archs "$app/Contents/MacOS/Inkpeg" | tr ' ' '\n' | sort | tr '\n' ' ')"
  [[ "$actual_slices" == 'arm64 x86_64 ' ]] || { printf 'Expected arm64 x86_64; merged %s.\n' "$actual_slices" >&2; exit 2; }
else
  cp "$package_root/Inkpeg-$architectures" "$app/Contents/MacOS/Inkpeg"
fi
python3 scripts/release-tools.py plist --out "$app/Contents/Info.plist"
cp packaging/brand/Inkpeg.icns "$app/Contents/Resources/Inkpeg.icns"
ditto --norsrc --noextattr packaging/starter-workspace "$app/Contents/Resources/StarterWorkspace"
# Do not carry workspace backup visibility flags into the product examples.
/usr/bin/chflags -R nohidden "$app/Contents/Resources/StarterWorkspace"
cp packaging/brand/dmg-background.png "$app/Contents/Resources/dmg-background.png"
python3 scripts/release-tools.py source --out "$package_root/build-source-after.json"
python3 - "$package_root/build-source.json" "$package_root/build-source-after.json" <<'PYCHECK'
import json, sys
assert json.load(open(sys.argv[1]))["sha256"] == json.load(open(sys.argv[2]))["sha256"], "Build inputs changed during compilation"
PYCHECK
cp "$package_root/build-source.json" "$app/Contents/Resources/build-source.json"
"$app/Contents/MacOS/Inkpeg" --check-resources
printf '%s\n' "$app"
