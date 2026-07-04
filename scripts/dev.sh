#!/usr/bin/env bash
set -euo pipefail

# One-command local dev: starts the Zig API (:8080) and the web dev server
# (:3000, proxying /api -> :8080) together, then shuts both down cleanly on
# Ctrl-C. Runnable from anywhere — resolves paths relative to the repo root.
cd "$(dirname "$0")/.."

pids=()

cleanup() {
  trap - INT TERM EXIT
  echo
  echo "shutting down dev servers..."
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# Seed the backend-private store on first run. data.json is the live, mutable
# store (gitignored); data.seed.json is the tracked reference seed.
if [ ! -f api/data.json ]; then
  echo "seeding api/data.json from api/data.seed.json ..."
  cp api/data.seed.json api/data.json
fi

echo "starting API on http://127.0.0.1:8080 ..."
( cd api && exec zig build run ) &
pids+=("$!")

echo "starting web on http://localhost:3000 (proxies /api -> :8080) ..."
( cd web && exec bun dev ) &
pids+=("$!")

# Wait for either server to exit; cleanup() then tears down the other.
wait -n
