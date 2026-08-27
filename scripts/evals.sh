#!/bin/zsh

# Runs the prompt eval suite against real Codex: each scenario sends the exact
# developer instructions, prompt, and output schema production sends, then
# scores the reply with the production decoder and validators (tier 1) and an
# LLM judge against a scenario rubric (tier 2). This costs real Codex usage,
# so it is never part of `swift test`.
#
# Usage:
#   scripts/evals.sh                                # full matrix, medium+high
#   scripts/evals.sh sprint-goal                    # scenario id prefix filter
#   scripts/evals.sh "" low,medium,high             # all scenarios, 3 efforts
#   scripts/evals.sh "" medium gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol
#
# Environment overrides:
#   SPEDITO_EVAL_MODEL         fallback model (default gpt-5.6-terra)
#   SPEDITO_EVAL_REPS          repetitions per cell (default 1)
#   SPEDITO_EVAL_JUDGE_MODEL   judge model (default: same as model)
#   SPEDITO_EVAL_JUDGE_EFFORT  judge effort (default high)
#   SPEDITO_EVAL_SKIP_JUDGE=1  deterministic tier 1 only
#   SPEDITO_EVAL_CODEX         explicit Codex executable path
#
# Results land in .eval-runs/<timestamp>/ (metadata.json, results.json,
# report.md). results.json is rewritten after every cell, so an interrupted
# run still leaves scoreable evidence.

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
cd "$project_root"

scenarios=${1:-}
efforts=${2:-medium,high}
models=${3:-${SPEDITO_EVAL_MODEL:-gpt-5.6-terra}}
runs_root="$project_root/.eval-runs"
mkdir -p "$runs_root"

print "Scenarios: ${scenarios:-all}"
print "Efforts:   $efforts"
print "Models:    $models"
print "Bundles:   $runs_root"
print ""

env \
  SPEDITO_EVALS=1 \
  SPEDITO_EVAL_SCENARIOS="$scenarios" \
  SPEDITO_EVAL_EFFORTS="$efforts" \
  SPEDITO_EVAL_MODELS="$models" \
  SPEDITO_EVAL_RUNS="$runs_root" \
  SWIFT_MODULECACHE_PATH="$project_root/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-cache" \
  swift test --filter 'Evals' 2>&1

print ""
print "Latest bundle:"
ls -dt "$runs_root"/*/ 2>/dev/null | head -1
