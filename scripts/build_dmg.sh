#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
app_path=${1:-"$project_root/.build/app/release/Spedito.app"}
output_path=${2:-"$project_root/.build/app/release/Spedito.dmg"}
volume_name=${SPEDITO_DMG_VOLUME_NAME:-Spedito}
background_path="$project_root/Distribution/DMGBackground.png"
volume_icon_path="$project_root/Sources/SpeditoApp/Resources/AppIcon.icns"
layout_script="$script_dir/layout_dmg.applescript"

if [[ ! -d "$app_path" ]]; then
  echo "Application bundle does not exist: $app_path" >&2
  exit 66
fi

if [[ ! -f "$background_path" ]]; then
  echo "DMG background does not exist: $background_path" >&2
  exit 66
fi

if [[ ! -f "$volume_icon_path" ]]; then
  echo "DMG volume icon does not exist: $volume_icon_path" >&2
  exit 66
fi

case "$output_path" in
  *.dmg)
    ;;
  *)
    echo "DMG output must end in .dmg: $output_path" >&2
    exit 64
    ;;
esac

output_parent=${output_path:h}
mkdir -p "$output_parent"

dmg_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/spedito-dmg.XXXXXX")
staging_dir="$dmg_work_dir/staging"
read_write_dmg="$dmg_work_dir/Spedito-read-write.dmg"
attached_device=""
mount_dir=""
mounted=false

cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$attached_device" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$dmg_work_dir"
}
trap cleanup EXIT

mkdir -p "$staging_dir/.background"
ditto "$app_path" "$staging_dir/Spedito.app"
ln -s /Applications "$staging_dir/Applications"
install -m 644 "$background_path" "$staging_dir/.background/background.png"

hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$read_write_dmg" >/dev/null
hdiutil resize -size +5m "$read_write_dmg" >/dev/null

attach_output=$(
  hdiutil attach \
    "$read_write_dmg" \
    -readwrite \
    -noverify \
    -noautoopen \
    -nobrowse \
    -owners off \
    -mountrandom /Volumes
)
attached_device=$(
  print -r -- "$attach_output" |
    awk '$1 ~ /^\/dev\// { device = $1 } END { print device }'
)
mount_dir=$(
  print -r -- "$attach_output" |
    awk '$1 ~ /^\/dev\// && $NF ~ /^\/Volumes\// { print $NF; exit }'
)

if [[ -z "$attached_device" || -z "$mount_dir" || ! -d "$mount_dir" ]]; then
  echo "Could not identify the mounted DMG device and volume." >&2
  if [[ -n "$attached_device" ]]; then
    hdiutil detach "$attached_device" -force >/dev/null 2>&1 || true
  fi
  exit 70
fi
mounted=true
finder_disk_name=${mount_dir:t}

install -m 644 "$volume_icon_path" "$mount_dir/.VolumeIcon.icns"
xcrun SetFile -c icnC "$mount_dir/.VolumeIcon.icns"
xcrun SetFile -a V "$mount_dir/.VolumeIcon.icns"
xcrun SetFile -a C "$mount_dir"

# Finder learns about newly attached volumes asynchronously on hosted runners.
sleep 5

layout_attempt=1
until osascript "$layout_script" "$finder_disk_name"; do
  if (( layout_attempt >= 3 )); then
    echo "Finder could not persist the DMG layout after $layout_attempt attempts." >&2
    exit 70
  fi
  layout_attempt=$((layout_attempt + 1))
  sleep 2
done

xcrun SetFile -a V "$mount_dir/.background"
sync

hdiutil detach "$attached_device" >/dev/null
mounted=false

rm -f "$output_path"
hdiutil convert \
  "$read_write_dmg" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$output_path" >/dev/null

hdiutil verify "$output_path" >/dev/null
echo "$output_path"
