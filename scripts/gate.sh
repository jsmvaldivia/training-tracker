#!/usr/bin/env bash
set -uo pipefail

# The local gate (issue #38): every deterministic check, in order, one process.
# Stops at the first failure and exits non-zero. Writes .gate/result.json so the
# evaluator agent reads results instead of re-running commands. A step that
# does not run is recorded as "skipped" with a reason — never as "passed".
#
# Usage: scripts/gate.sh
#   GATE_SKIP="e2e perf"   skip named steps (recorded as skipped, not passed)
#
# Runnable from anywhere — resolves paths relative to the repo root.
cd "$(dirname "$0")/.."

OUT_DIR=".gate"
RESULT="$OUT_DIR/result.json"
STEPS_FILE="$OUT_DIR/steps.ndjson"
PERF_SCRIPT="scripts/perf-snapshot.sh"   # created by issue #35
TAIL_LINES=40

mkdir -p "$OUT_DIR"
: > "$STEPS_FILE"

for tool in jq lsof python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 2; }
done

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
if pgrep -f "zig build test" >/dev/null; then
  echo "error: another 'zig build test' is running; it would race on /tmp data paths" >&2
  exit 2
fi
# Playwright starts its own server on :3000; a stale dev server would be reused.
if lsof -i :3000 -sTCP:LISTEN -n -P >/dev/null 2>&1; then
  echo "error: port 3000 is held; stop the dev server before running the gate" >&2
  exit 2
fi

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export PLAYWRIGHT_HTML_OPEN=never   # never block on the HTML report server
echo "gate: $(git rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git rev-parse --short HEAD 2>/dev/null)"

# ---- steps, in order ---------------------------------------------------------
# Worktrees start without node_modules; frozen install is a no-op when warm.
run_step deps       web  bun install --frozen-lockfile
run_step fmt        api  zig fmt --check .
run_step oas-lint   .    scripts/validate-oas.sh
run_step zig-test   api  zig build test
run_step unit-cov   web  bun run test:unit
run_step e2e        web  bun run test:e2e

if (( failed )); then
  skip_step perf "earlier step failed: $skip_reason"
elif skipped_by_env perf; then
  skip_step perf "skipped by GATE_SKIP"
elif [[ -x "$PERF_SCRIPT" ]]; then
  run_step perf . "$PERF_SCRIPT"
else
  skip_step perf "no perf instrumentation yet (issue #35)"
fi

finish
