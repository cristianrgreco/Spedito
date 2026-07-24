#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
app_path="$project_root/.build/arm64-apple-macosx/debug/StoryPointless"

cd "$project_root"

env \
  SWIFT_MODULECACHE_PATH="$project_root/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-cache" \
  swift build -Xswiftc -warnings-as-errors

pkill -9 -x StoryPointless 2>/dev/null || true
exec "$app_path"
