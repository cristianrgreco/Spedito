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
terminate_staged_app() {
  local termination_deadline=$((SECONDS + 5))

  /usr/bin/pkill -TERM -f "$staged_executable" 2>/dev/null || true
  while /usr/bin/pgrep -f "$staged_executable" >/dev/null 2>&1; do
    if (( SECONDS >= termination_deadline )); then
      /usr/bin/pkill -KILL -f "$staged_executable" 2>/dev/null || true
      break
    fi
    sleep 1
  done
}
release_lock() {
  local exit_status=$?
  trap - EXIT
  if [[ "$lock_acquired" == true ]]; then
    terminate_staged_app
    rm -rf "$staged_root"
    rm -f "$lock_directory/owner"
    rmdir "$lock_directory" 2>/dev/null || true
    lock_acquired=false
  fi
  exit "$exit_status"
}
reclaim_stale_lock() {
  local owner_file="$lock_directory/owner"
  local owner_pid=""
  local line
  local stale_lock

  [[ -f "$owner_file" ]] || return 1
  while IFS= read -r line; do
    case "$line" in
      pid=*)
        owner_pid="${line#pid=}"
        break
        ;;
    esac
  done < "$owner_file"

  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null && return 1

  stale_lock="${lock_directory}.stale.$$.$RANDOM"
  if mv "$lock_directory" "$stale_lock" 2>/dev/null; then
    rm -rf "$stale_lock"
    printf 'Reclaimed stale Spedito UI-test lock previously owned by pid %s.\n' \
      "$owner_pid" >&2
    return 0
  fi
  return 1
}
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

started_waiting_at=$SECONDS
while ! mkdir "$lock_directory" 2>/dev/null; do
  if reclaim_stale_lock; then
    continue
  fi
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
terminate_staged_app


env \
  SPEDITO_BUNDLE_IDENTIFIER=io.spedito.app.ui-testing \
  SPEDITO_SIGN_IDENTITY=- \
  ./scripts/build_app.sh debug

rm -rf "$staged_root"
mkdir -p "$staged_root"
/usr/bin/ditto ".build/app/debug/Spedito.app" "$staged_app_path"

test_output="$staged_root/xcodebuild.log"
test_identifiers=()

xcodebuild \
  -project SpeditoUITests.xcodeproj \
  -scheme SpeditoUITests \
  -destination 'platform=macOS' \
  -derivedDataPath "$staged_root/derived" \
  -parallel-testing-enabled NO \
  build-for-testing \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES

if (( ${#only_testing[@]} == 1 )); then
  test_identifiers[0]="${only_testing[0]#-only-testing:}"
else
  enumeration_output="$staged_root/test-enumeration.txt"
  xcodebuild \
    -project SpeditoUITests.xcodeproj \
    -scheme SpeditoUITests \
    -destination 'platform=macOS' \
    -derivedDataPath "$staged_root/derived" \
    -parallel-testing-enabled NO \
    test-without-building \
    -enumerate-tests \
    -test-enumeration-style flat \
    -test-enumeration-format text \
    -test-enumeration-output-path "$enumeration_output" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    >/dev/null

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      $'\t'*'()')
        test_identifiers[${#test_identifiers[@]}]="${line:1}"
        ;;
    esac
  done < "$enumeration_output"
fi

if (( ${#test_identifiers[@]} == 0 )); then
  printf 'Launched-process test failure: xcodebuild enumerated no tests.\n' >&2
  exit 1
fi

run_ui_test() {
  local test_identifier="$1"
  local command_status=0
  local individual_output="$staged_root/xcodebuild-current.log"

  if xcodebuild \
    -project SpeditoUITests.xcodeproj \
    -scheme SpeditoUITests \
    -destination 'platform=macOS' \
    -derivedDataPath "$staged_root/derived" \
    -parallel-testing-enabled NO \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 180 \
    test-without-building \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    "-only-testing:$test_identifier" \
    2>&1 | tee "$individual_output"; then
    if ! /usr/bin/grep -Eq 'Executed 1 test, with 0 failures' "$individual_output"; then
      printf 'Launched-process test failure: xcodebuild reported no executed test for %s.\n' \
        "$test_identifier" >&2
      return 1
    fi
    cat "$individual_output" >> "$test_output"
    return 0
  else
    command_status=${PIPESTATUS[0]}
  fi

  return "$command_status"
}

: > "$test_output"
test_count=${#test_identifiers[@]}
executed_count=0
for test_identifier in "${test_identifiers[@]}"; do
  printf 'Running launched-process contract %s of %s: %s\n' \
    "$((executed_count + 1))" "$test_count" "$test_identifier"
  run_ui_test "$test_identifier"
  executed_count=$((executed_count + 1))
  terminate_staged_app
  if (( executed_count < test_count )); then
    sleep 5
  fi
done

if (( executed_count != test_count )); then
  printf 'Launched-process test failure: expected %s executed tests, observed %s.\n' \
    "$test_count" "$executed_count" >&2
  exit 1
fi

printf 'Executed %s tests, with 0 failures (serialized launched-process aggregate).\n' \
  "$test_count"
