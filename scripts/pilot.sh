#!/bin/zsh

# Drives Spedito end to end as a product owner, against real Codex, real Git,
# and real demo launching. This costs real Codex usage and takes minutes to
# hours, so it is never part of `swift test`.
#
# Usage:
#   scripts/pilot.sh                     # default brief
#   scripts/pilot.sh native-notes        # a named brief
#   scripts/pilot.sh native-notes 3600   # brief and budget in seconds
#
# Findings and evidence land in .pilot-runs/<timestamp>-<brief>/.

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

brief=${1:-static-converter}
budget=${2:-1800}
runs_root="$project_root/.pilot-runs"
mkdir -p "$runs_root"

print "Pilot brief:  $brief"
print "Budget:       ${budget}s"
print "Bundles:      $runs_root"
print ""

env \
  SPEDITO_PILOT=1 \
  SPEDITO_PILOT_BRIEF="$brief" \
  SPEDITO_PILOT_BUDGET_SECONDS="$budget" \
  SPEDITO_PILOT_RUNS="$runs_root" \
  SWIFT_MODULECACHE_PATH="$project_root/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-cache" \
  swift test --filter 'Pilot' 2>&1

print ""
print "Latest bundle:"
ls -dt "$runs_root"/*/ 2>/dev/null | head -1
