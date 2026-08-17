#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/run_ui_tests.sh [-only-testing:<target>]

Runs the launched-process UI contracts under a machine-wide lock. Pass one
xcodebuild -only-testing: filter to run only the affected contract.
EOF
}

if (( $# > 1 )); then
  usage
  exit 64
fi

only_testing=()
if (( $# == 1 )); then
  if [[ "$1" != -only-testing:* ]]; then
    usage
    exit 64
  fi
  only_testing=("$1")
fi

lock_timeout_seconds="${SPEDITO_UI_TEST_LOCK_TIMEOUT_SECONDS:-600}"
if [[ ! "$lock_timeout_seconds" =~ ^[0-9]+$ ]]; then
  printf 'SPEDITO_UI_TEST_LOCK_TIMEOUT_SECONDS must be a non-negative integer, got %q.\n' \
    "$lock_timeout_seconds" >&2
  exit 64
fi

lock_directory="/tmp/spedito-ui-tests-${UID}.lock"
staged_root="/tmp/spedito-ui-tests-${UID}"
staged_app_path="$staged_root/Spedito.app"
staged_executable="$staged_app_path/Contents/MacOS/Spedito"
lock_acquired=false
release_lock() {
  if [[ "$lock_acquired" == true ]]; then
    /usr/bin/pkill -TERM -f -x "$staged_executable" 2>/dev/null || true
    rm -rf "$staged_root"
    rm -f "$lock_directory/owner"
    rmdir "$lock_directory" 2>/dev/null || true
    lock_acquired=false
  fi
}
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

started_waiting_at=$SECONDS
while ! mkdir "$lock_directory" 2>/dev/null; do
  if (( SECONDS - started_waiting_at >= lock_timeout_seconds )); then
    printf 'Timed out after %s seconds waiting for the machine-wide Spedito UI-test lock at %s. Another agent may be building or driving the shared GUI session; retry after it finishes.\n' \
      "$lock_timeout_seconds" "$lock_directory" >&2
    exit 75
  fi
  sleep 1
done
lock_acquired=true
printf 'pid=%s\nrepository=%s\n' "$$" "$PWD" > "$lock_directory/owner"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

env \
  SPEDITO_BUNDLE_IDENTIFIER=io.spedito.app.ui-testing \
  SPEDITO_SIGN_IDENTITY=- \
  ./scripts/build_app.sh debug

rm -rf "$staged_root"
mkdir -p "$staged_root"
/usr/bin/ditto ".build/app/debug/Spedito.app" "$staged_app_path"

xcodebuild \
  -project SpeditoUITests.xcodeproj \
  -scheme SpeditoUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$staged_root/derived" \
  -parallel-testing-enabled NO \
  test \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  "${only_testing[@]}"
