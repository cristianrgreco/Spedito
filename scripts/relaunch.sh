#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
app_path="$project_root/.build/app/debug/Spedito.app"
info_plist="$app_path/Contents/Info.plist"
github_client_id=${SPEDITO_GITHUB_CLIENT_ID:-}
github_app_slug=${SPEDITO_GITHUB_APP_SLUG:-}

if [[ -f "$info_plist" ]]; then
  if [[ -z "$github_client_id" ]]; then
    github_client_id=$(plutil -extract SpeditoGitHubClientID raw "$info_plist" 2>/dev/null || true)
  fi
  if [[ -z "$github_app_slug" ]]; then
    github_app_slug=$(plutil -extract SpeditoGitHubAppSlug raw "$info_plist" 2>/dev/null || true)
  fi
fi

cd "$project_root"

SPEDITO_GITHUB_CLIENT_ID="$github_client_id" \
  SPEDITO_GITHUB_APP_SLUG="$github_app_slug" \
  "$script_dir/build_app.sh" debug

pkill -9 -x StoryPointless 2>/dev/null || true
pkill -9 -x Spedito 2>/dev/null || true
exec "$app_path/Contents/MacOS/Spedito"
