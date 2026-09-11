#!/usr/bin/env bash
set -uo pipefail

# The local gate (issues #38, #12): every deterministic check, in order, in one
# process. Stops at the first failure and exits non-zero. Writes
# .gate/result.json so the evaluator agent reads results instead of re-running
# commands; a step that does not run is recorded as "skipped" with a reason,
# never as "passed".
#
# Steps: tools (versions against mise.toml), deps (bun install), fmt (zig fmt),
# oas-lint (Spectral), zig-test (the full Zig suite), unit-cov (bun test with
# the coverage threshold), e2e (mocked Playwright), e2e-live (real API on a
# scratch store), perf (scripts/perf-snapshot.sh; skipped when oha is absent).
#
# Usage: scripts/gate.sh
#   GATE_SKIP="e2e perf"   skip named steps (recorded as skipped, not passed)
cd "$(dirname "$0")/.."
. scripts/lib.sh

OUT_DIR=".gate"
RESULT="$OUT_DIR/result.json"
STEPS_FILE="$OUT_DIR/steps.ndjson"
TAIL_LINES=40

mkdir -p "$OUT_DIR"
: > "$STEPS_FILE"

require_tools jq lsof python3

failed=0
skip_reason=""

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

record() { # name status exit_code duration_ms log_file reason
  local name="$1" status="$2" code="$3" ms="$4" log="$5" reason="$6"
  local tail_text=""
  [[ -f "$log" ]] && tail_text="$(tail -n "$TAIL_LINES" "$log")"
  jq -cn \
    --arg name "$name" --arg status "$status" --argjson exit_code "$code" \
    --argjson duration_ms "$ms" --arg reason "$reason" --arg tail "$tail_text" \
    '{name:$name,status:$status,exit_code:$exit_code,duration_ms:$duration_ms,reason:$reason,output_tail:$tail}' \
    >> "$STEPS_FILE"
}

skipped_by_env() {
  local name="$1"
  for s in ${GATE_SKIP:-}; do [[ "$s" == "$name" ]] && return 0; done
  return 1
}

run_step() { # name workdir command...
  local name="$1" dir="$2"; shift 2
  local log="$OUT_DIR/$name.log"
  : > "$log"

  if (( failed )); then
    record "$name" skipped 0 0 "$log" "earlier step failed: $skip_reason"
    printf '  %-9s %s\n' skipped "$name"
    return
  fi
  if skipped_by_env "$name"; then
    record "$name" skipped 0 0 "$log" "skipped by GATE_SKIP"
    printf '  %-9s %s (GATE_SKIP)\n' skipped "$name"
    return
  fi

  printf '  %-9s %s ... ' running "$name"
  local start end code
  start=$(now_ms)
  ( cd "$dir" && "$@" ) >"$log" 2>&1
  code=$?
  end=$(now_ms)
  if (( code == 0 )); then
    record "$name" passed 0 $((end - start)) "$log" ""
    echo "passed ($(( (end - start) / 1000 ))s)"
  else
    failed=1; skip_reason="$name"
    record "$name" failed "$code" $((end - start)) "$log" ""
    echo "FAILED (exit $code, see $log)"
  fi
}

skip_step() { # name reason
  local name="$1" reason="$2"
  local log="$OUT_DIR/$name.log"
  : > "$log"
  record "$name" skipped 0 0 "$log" "$reason"
  printf '  %-9s %s (%s)\n' skipped "$name" "$reason"
}

finish() {
  local overall="passed"
  (( failed )) && overall="failed"
  jq -s --arg overall "$overall" \
        --arg started_at "$STARTED_AT" \
        --arg commit "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
        --arg branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)" \
        '{overall:$overall,started_at:$started_at,commit:$commit,branch:$branch,steps:.}' \
        "$STEPS_FILE" > "$RESULT"
  rm -f "$STEPS_FILE"
  echo
  echo "gate: $overall — $RESULT"
  (( failed )) && exit 1
  exit 0
}

# ---- preconditions ---------------------------------------------------------
# Zig test binaries share hardcoded /tmp data paths: never two runs at once.
# `-j1` also serializes the per-file binaries within this one build.
if pgrep -f "zig build test" >/dev/null; then
  echo "error: another 'zig build test' is running; it would race on /tmp data paths" >&2
  exit 2
fi
# Playwright starts its own server on :3000; a stale dev server would be reused.
require_port_free 3000 "stop the dev server before running the gate"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export PLAYWRIGHT_HTML_OPEN=never   # never block on the HTML report server
echo "gate: $(git rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git rev-parse --short HEAD 2>/dev/null)"

# ---- steps, in order ---------------------------------------------------------
run_step tools      .    scripts/check-tools.sh
# Worktrees start without node_modules; frozen install is a no-op when warm.
run_step deps       web  bun install --frozen-lockfile
run_step fmt        api  zig fmt --check .
run_step oas-lint   .    scripts/validate-oas.sh
run_step zig-test   api  zig build test -j1
run_step unit-cov   web  bun run test:unit
# The dev server reads PORT; pin it so a value exported by an IDE preview
# runner cannot move it off :3000, where Playwright waits.
run_step e2e        web  env PORT=3000 bun run test:e2e
run_step e2e-live   .    scripts/e2e-live.sh

if (( failed )); then
  skip_step perf "earlier step failed: $skip_reason"
elif skipped_by_env perf; then
  skip_step perf "skipped by GATE_SKIP"
elif ! command -v oha >/dev/null; then
  skip_step perf "oha is not installed"
else
  run_step perf . scripts/perf-snapshot.sh
fi

finish
