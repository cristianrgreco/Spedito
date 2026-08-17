#!/bin/zsh

set -euo pipefail

project_root=${1:?Project root is required}
info_plist=${2:?Info.plist path is required}
github_client_id=${SPEDITO_GITHUB_CLIENT_ID:-}
github_app_slug=${SPEDITO_GITHUB_APP_SLUG:-}

if command -v gh >/dev/null 2>&1; then
  if [[ -z "$github_client_id" ]]; then
    github_client_id=$(
      cd "$project_root"
      gh variable get SPEDITO_GITHUB_CLIENT_ID 2>/dev/null || true
    )
  fi
  if [[ -z "$github_app_slug" ]]; then
    github_app_slug=$(
      cd "$project_root"
      gh variable get SPEDITO_GITHUB_APP_SLUG 2>/dev/null || true
    )
  fi
fi

if [[ -f "$info_plist" ]]; then
  if [[ -z "$github_client_id" ]]; then
    github_client_id=$(plutil -extract SpeditoGitHubClientID raw "$info_plist" 2>/dev/null || true)
  fi
  if [[ -z "$github_app_slug" ]]; then
    github_app_slug=$(plutil -extract SpeditoGitHubAppSlug raw "$info_plist" 2>/dev/null || true)
  fi
fi

print -r -- "client_id=$github_client_id"
print -r -- "app_slug=$github_app_slug"
