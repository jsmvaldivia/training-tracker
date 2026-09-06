#!/usr/bin/env bash
set -euo pipefail

# Full-stack E2E (tier 5 in web/TESTING.md, issue #8): Playwright drives the
# real Bun proxy and the real Zig API against a scratch copy of the seed, with
# no route mocks. api/data.json is never read or written.
#
#   scripts/e2e-live.sh [playwright args...]   e.g. -g "lifecycle", --ui
#
#   API_PORT   API port (default 8081)
#   WEB_PORT   web port (default 3100; the mocked suite and dev use 3000)
#
# Both servers and the scratch store are removed on exit — success, failure,
# or Ctrl-C. Runnable from anywhere; resolves paths relative to the repo root.
cd "$(dirname "$0")/.."
root="$PWD"

API_PORT="${API_PORT:-8081}"
WEB_PORT="${WEB_PORT:-3100}"

for tool in zig bun curl; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 2; }
done
for port in "$API_PORT" "$WEB_PORT"; do
  if lsof -i ":$port" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
    echo "error: port $port is held; set API_PORT/WEB_PORT or stop that server" >&2
    exit 2
  fi
done

# One scratch directory per run: the store, its atomic-write temp files, and
# the server logs. The rollback spec makes it read-only mid-run, so cleanup
# restores write permission before removing it.
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/tt-e2e-live.XXXXXX")"
scratch="$scratch_dir/data.json"
cp api/data.seed.json "$scratch"

api_pid=""
web_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  trap '' INT TERM
  for pid in "$web_pid" "$api_pid"; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "$web_pid" "$api_pid"; do
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
  chmod -R u+w "$scratch_dir" 2>/dev/null || true
  rm -rf "$scratch_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for() { # url what
  local url="$1" what="$2"
  for _ in $(seq 1 300); do
    if curl -sf "$url" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  echo "error: $what did not become ready at $url" >&2
  return 1
}

echo "e2e-live: building API ..."
(cd api && zig build)

echo "e2e-live: API on :$API_PORT, store $scratch"
PORT="$API_PORT" DATA_PATH="$scratch" api/zig-out/bin/training-tracker > "$scratch_dir/api.log" 2>&1 &
api_pid=$!
wait_for "http://127.0.0.1:$API_PORT/health" "API"

echo "e2e-live: web on :$WEB_PORT (proxying /api -> :$API_PORT)"
(cd web && PORT="$WEB_PORT" BACKEND_URL="http://127.0.0.1:$API_PORT" exec bun server.ts) > "$scratch_dir/web.log" 2>&1 &
web_pid=$!
wait_for "http://127.0.0.1:$WEB_PORT/" "web server"

cd web
E2E_LIVE_DATA_PATH="$scratch" WEB_PORT="$WEB_PORT" \
  bun node_modules/@playwright/test/cli.js test -c playwright.live.config.ts "$@"
