#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
app_path="${1:-$project_root/.build/app/release/Spedito.app}"
output_path="${2:-$project_root/.build/app/release/Spedito.dmg}"
volume_name="${SPEDITO_DMG_VOLUME_NAME:-Spedito}"
background_path="$project_root/Distribution/DMGBackground.tiff"

if [[ ! -d "$app_path" ]]; then
  echo "Application bundle does not exist: $app_path" >&2
  exit 66
fi

if [[ ! -f "$background_path" ]]; then
  echo "DMG background does not exist: $background_path" >&2
  exit 66
fi

create_dmg="${CREATE_DMG_EXECUTABLE:-create-dmg}"
if ! command -v "$create_dmg" >/dev/null 2>&1; then
  echo "create-dmg is required. Set CREATE_DMG_EXECUTABLE to a reviewed executable." >&2
  exit 69
fi

case "$output_path" in
  *.dmg)
    ;;
  *)
    echo "DMG output must end in .dmg: $output_path" >&2
    exit 64
    ;;
esac

output_parent="$(dirname "$output_path")"
mkdir -p "$output_parent"

dmg_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/spedito-dmg.XXXXXX")"
staging_dir="$dmg_work_dir/staging"

cleanup() {
  rm -rf "$dmg_work_dir"
}
trap cleanup EXIT

mkdir -p "$staging_dir"
ditto "$app_path" "$staging_dir/Spedito.app"

# create-dmg refuses to overwrite an existing output file.
rm -f "$output_path"

"$create_dmg" \
  --volname "$volume_name" \
  --background "$background_path" \
  --window-pos 180 140 \
  --window-size 660 468 \
  --icon-size 112 \
  --text-size 13 \
  --icon "Spedito.app" 180 240 \
  --hide-extension "Spedito.app" \
  --app-drop-link 480 240 \
  --no-internet-enable \
  "$output_path" \
  "$staging_dir"

echo "$output_path"
