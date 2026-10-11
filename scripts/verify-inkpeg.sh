#!/bin/bash
# Fresh, retained evidence folder. No install, signing, Git or security changes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="${1:-$(mktemp -d /tmp/inkpeg-verification.XXXXXX)}"
if [[ -n "${1:-}" ]]; then mkdir "$work"; fi
work="$(cd "$work" && pwd)"
printf '%s\n' "$work" > "$work/evidence-directory.txt"
run() {
  local name="$1"; shift
  printf '%q ' "$@" > "$work/$name.command"; printf '\n' >> "$work/$name.command"
  local status=0
  "$@" > "$work/$name.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$work/$name.exit"
  cat "$work/$name.log"
  return "$status"
}
run release-contract python3 scripts/test-release.py
run native env -i PATH=/usr/bin:/bin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LANG=en_US.UTF-8 /usr/bin/swift test --scratch-path "$work/swift-tests"
run build env -i PATH=/usr/bin:/bin:/opt/homebrew/bin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LANG=en_US.UTF-8 /bin/bash scripts/build-inkpeg.sh --configuration release --architectures universal --no-sign
app="$(tail -n 1 "$work/build.log")"
run package env -i PATH=/usr/bin:/bin:/opt/homebrew/bin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer LANG=en_US.UTF-8 /bin/bash scripts/package-inkpeg.sh --app "$app" --output "$work/release"
printf '%s\n' "$app" > "$work/app-path.txt"
printf 'Retained evidence: %s\n' "$work"
printf '%s\n' 'Next: inspect mounted DMG and isolated copies; prepare site manifest; run scripts/check-site.py against the served final site. See docs/inkpeg/VERIFICATION.md.'
