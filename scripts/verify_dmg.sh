#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}

fail() {
  echo "$1" >&2
  exit 65
}

if (( $# != 1 )); then
  echo "Usage: $0 <Spedito.dmg>" >&2
  exit 64
fi

dmg_path=${1:A}
if [[ ! -f "$dmg_path" ]]; then
  echo "DMG does not exist: $dmg_path" >&2
  exit 66
fi

verify_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/spedito-dmg-verify.XXXXXX")
mount_dir="$verify_work_dir/mount"
mounted=false

cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$verify_work_dir"
}
trap cleanup EXIT

mkdir -p "$mount_dir"
hdiutil verify "$dmg_path" >/dev/null
hdiutil attach \
  "$dmg_path" \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$mount_dir" >/dev/null
mounted=true

[[ -d "$mount_dir/Spedito.app" ]] ||
  fail "The DMG does not contain Spedito.app."
[[ -L "$mount_dir/Applications" ]] ||
  fail "The DMG does not contain the Applications shortcut."
[[ "$(readlink "$mount_dir/Applications")" == "/Applications" ]] ||
  fail "The Applications shortcut does not target /Applications."
[[ -f "$mount_dir/.background/DMGBackground.png" ]] ||
  fail "The DMG background is missing."
cmp -s \
  "$project_root/Distribution/DMGBackground.png" \
  "$mount_dir/.background/DMGBackground.png" ||
  fail "The DMG background does not match the release asset."
[[ -s "$mount_dir/.DS_Store" ]] ||
  fail "The Finder drag-and-drop layout was not persisted."
[[ -f "$mount_dir/Spedito.app/Contents/Resources/LICENSE.txt" ]] ||
  fail "The application does not contain its licence."
cmp -s \
  "$project_root/LICENSE" \
  "$mount_dir/Spedito.app/Contents/Resources/LICENSE.txt" ||
  fail "The bundled licence does not match the repository licence."

codesign --verify --deep --strict "$mount_dir/Spedito.app"

binary_architectures=$(
  lipo -archs "$mount_dir/Spedito.app/Contents/MacOS/Spedito"
)
if [[ " $binary_architectures " != *" arm64 "* ]]; then
  echo "The DMG does not contain an Apple Silicon application." >&2
  exit 65
fi

hdiutil detach "$mount_dir" >/dev/null
mounted=false

echo "Verified $dmg_path"
