#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${SPEDITO_ARCHITECTURE_ROOT:-${script_dir:h}}
baseline_file=${SPEDITO_ARCHITECTURE_BASELINE:-$script_dir/architecture_ratchets.baseline}
app_model="$project_root/Sources/SpeditoApp/AppModel.swift"
content_view="$project_root/Sources/SpeditoApp/ContentView.swift"

for required_file in "$baseline_file" "$app_model" "$content_view"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Architecture ratchet input is missing: $required_file" >&2
    exit 66
  fi
done

metric_label() {
  case "$1" in
    app_model_lines) echo 'AppModel.swift lines' ;;
    content_view_lines) echo 'ContentView.swift lines' ;;
    app_model_published) echo 'AppModel @Published sites' ;;
    app_model_try_optional) echo 'AppModel try? sites' ;;
    app_model_task_sites) echo 'AppModel task-launch sites' ;;
    content_view_task_sites) echo 'ContentView task-launch sites' ;;
    *) return 1 ;;
  esac
}

metric_value() {
  case "$1" in
    app_model_lines)
      wc -l < "$app_model" | tr -d '[:space:]'
      ;;
    content_view_lines)
      wc -l < "$content_view" | tr -d '[:space:]'
      ;;
    app_model_published)
      grep -c '@Published' "$app_model" || true
      ;;
    app_model_try_optional)
      grep -c 'try?' "$app_model" || true
      ;;
    app_model_task_sites)
      grep -Ec 'Task \{|Task\(priority' "$app_model" || true
      ;;
    content_view_task_sites)
      grep -Ec 'Task \{|Task\(priority' "$content_view" || true
      ;;
    *) return 1 ;;
  esac
}

expected_metric_count=6
seen_metric_count=0
failed=0

while IFS='=' read -r key baseline; do
  [[ -z "$key" ]] && continue

  label=$(metric_label "$key") || {
    echo "Unknown architecture ratchet metric: $key" >&2
    exit 65
  }
  actual=$(metric_value "$key")

  if [[ "$baseline" != <-> || "$actual" != <-> ]]; then
    echo "Architecture ratchet values must be non-negative integers: $key baseline=$baseline actual=$actual" >&2
    exit 65
  fi

  seen_metric_count=$((seen_metric_count + 1))
  if (( actual > baseline )); then
    echo "Architecture ratchet failed: $label; baseline=$baseline actual=$actual." >&2
    echo "Fix: reduce $key to $baseline; raising the baseline requires an explicit packet reason." >&2
    failed=1
  elif (( actual < baseline )); then
    echo "Architecture improvement is not locked in: $label; baseline=$baseline actual=$actual." >&2
    echo "Fix: set $key=$actual in $baseline_file." >&2
    failed=1
  fi
done < "$baseline_file"

if (( seen_metric_count != expected_metric_count )); then
  echo "Architecture baseline must contain exactly $expected_metric_count metrics; found $seen_metric_count." >&2
  exit 65
fi

if (( failed != 0 )); then
  exit 1
fi

printf 'Architecture ratchets match all %d baselines.\n' "$seen_metric_count"
