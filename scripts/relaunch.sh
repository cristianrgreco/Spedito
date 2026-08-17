#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
app_path="$project_root/.build/app/debug/Spedito.app"
info_plist="$app_path/Contents/Info.plist"
github_config=("${(@f)$("$script_dir/resolve_github_app_config.sh" "$project_root" "$info_plist")}")
if (( ${#github_config[@]} != 2 )); then
  echo "GitHub App configuration resolver returned an invalid result." >&2
  exit 70
fi
if [[ "${github_config[1]}" != client_id=* || "${github_config[2]}" != app_slug=* ]]; then
  echo "GitHub App configuration resolver returned an invalid result." >&2
  exit 70
fi
github_client_id=${github_config[1]#client_id=}
github_app_slug=${github_config[2]#app_slug=}

cd "$project_root"

SPEDITO_GITHUB_CLIENT_ID="$github_client_id" \
  SPEDITO_GITHUB_APP_SLUG="$github_app_slug" \
  "$script_dir/build_app.sh" debug

pkill -9 -x StoryPointless 2>/dev/null || true
pkill -9 -x Spedito 2>/dev/null || true
exec "$app_path/Contents/MacOS/Spedito"
