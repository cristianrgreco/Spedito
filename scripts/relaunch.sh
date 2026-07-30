#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
app_path="$project_root/.build/app/debug/StoryPointless.app"

cd "$project_root"

"$script_dir/build_app.sh" debug

pkill -9 -x StoryPointless 2>/dev/null || true
exec "$app_path/Contents/MacOS/StoryPointless"
