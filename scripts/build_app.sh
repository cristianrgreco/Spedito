#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
configuration=${1:-release}

case "$configuration" in
  debug|release)
    ;;
  *)
    echo "Usage: $0 [debug|release]" >&2
    exit 64
    ;;
esac

bundle_identifier=${SPEDITO_BUNDLE_IDENTIFIER:-io.spedito.app}
marketing_version=${SPEDITO_VERSION:-0.1.0}
build_number=${SPEDITO_BUILD_NUMBER:-1}
signing_identity=${SPEDITO_SIGN_IDENTITY:--}
github_client_id=${SPEDITO_GITHUB_CLIENT_ID:-}
github_app_slug=${SPEDITO_GITHUB_APP_SLUG:-}
app_output_directory=${SPEDITO_APP_OUTPUT_DIRECTORY:-"$project_root/.build/app/$configuration"}

cd "$project_root"

env \
  SWIFT_MODULECACHE_PATH="$project_root/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-cache" \
  swift build -c "$configuration" -Xswiftc -warnings-as-errors

binary_directory=$(
  env \
    SWIFT_MODULECACHE_PATH="$project_root/.build/module-cache" \
    CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-cache" \
    swift build -c "$configuration" --show-bin-path
)
binary_path="$binary_directory/Spedito"
app_path="$app_output_directory/Spedito.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"

case "$app_output_directory" in
  /*)
    ;;
  *)
    echo "App output directory must be absolute: $app_output_directory" >&2
    exit 70
    ;;
esac

rm -rf "$app_path"
mkdir -p "$macos_path" "$resources_path"

install -m 755 "$binary_path" "$macos_path/Spedito"
install -m 644 \
  "$project_root/Distribution/Info.plist" \
  "$contents_path/Info.plist"
install -m 644 \
  "$project_root/Sources/SpeditoApp/Resources/AppIcon.icns" \
  "$resources_path/AppIcon.icns"
install -m 644 \
  "$project_root/Sources/SpeditoApp/Resources/AppIcon.png" \
  "$resources_path/AppIcon.png"
install -m 644 \
  "$project_root/Sources/SpeditoApp/Resources/ticket-attention.wav" \
  "$resources_path/ticket-attention.wav"
install -m 644 \
  "$project_root/LICENSE" \
  "$resources_path/LICENSE.txt"

plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$contents_path/Info.plist"
plutil -replace CFBundleShortVersionString -string "$marketing_version" "$contents_path/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$contents_path/Info.plist"
plutil -replace SpeditoGitHubClientID -string "$github_client_id" "$contents_path/Info.plist"
plutil -replace SpeditoGitHubAppSlug -string "$github_app_slug" "$contents_path/Info.plist"

if [[ -n "$signing_identity" ]]; then
  signing_options=(--force --sign "$signing_identity")
  if [[ "$signing_identity" != "-" ]]; then
    signing_options+=(--options runtime --timestamp)
  fi
  codesign "${signing_options[@]}" "$app_path"
fi

echo "$app_path"
