#!/usr/bin/env bash
set -euo pipefail

# One-command local dev: starts the Zig API (:8080) and the web dev server
# (:3000, proxying /api -> :8080) together, then shuts both down cleanly on
# Ctrl-C.
cd "$(dirname "$0")/.."

# Bash job control puts each background command and its descendants in a
# separate process group, including zig's server and Bun's script process.
# This works in non-interactive Bash 3.2 too; no setsid or wait -n required.
set -m
pids=()

cleanup() {
  local status=$?
  trap - EXIT
  trap '' INT TERM
  echo "shutting down dev servers..."
  for pid in ${pids[@]+"${pids[@]}"}; do
    kill -TERM -- "-$pid" 2>/dev/null || true
  done
  # Allow graceful shutdown, but do not hang on an unresponsive descendant.
  for ((attempt = 0; attempt < 25; attempt++)); do
    local alive=false
    for pid in ${pids[@]+"${pids[@]}"}; do
      if kill -0 -- "-$pid" 2>/dev/null; then alive=true; fi
    done
    if [[ "$alive" == false ]]; then break; fi
    sleep 0.2
  done
  for pid in ${pids[@]+"${pids[@]}"}; do
    kill -KILL -- "-$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Seed the backend-private store on first run. data.json is the live, mutable
# store (gitignored); data.seed.json is the tracked reference seed.
if [ ! -f api/data.json ]; then
  echo "seeding api/data.json from api/data.seed.json ..."
  cp api/data.seed.json api/data.json
fi

# Both servers read PORT, so each gets its own value here rather than
# whatever the parent shell (or an IDE preview runner) exported.
echo "starting API on http://127.0.0.1:8080 ..."
( cd api && PORT=8080 exec zig build run ) &
pids+=("$!")

echo "starting web on http://localhost:3000 (proxies /api -> :8080) ..."
( cd web && PORT=3000 BACKEND_URL=http://127.0.0.1:8080 exec bun dev ) &
pids+=("$!")

# Bash 3.2 has no wait -n. Bash reaps completed jobs while retaining their
# status for wait, so polling the two leaders also handles clean exits.
while true; do
  for pid in "${pids[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      status=0
      wait "$pid" || status=$?
      exit "$status"
    fi
  done
  sleep 0.2
done
