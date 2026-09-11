#!/usr/bin/env bash
set -euo pipefail

# Full-stack E2E (issue #8): Playwright drives the real Bun proxy and the real
# Zig API against a scratch copy of the seed, with no route mocks.
# api/data.json is never read or written.
#
#   scripts/e2e-live.sh [playwright args...]   e.g. -g "lifecycle", --ui
#
#   API_PORT   API port (default 8081)
#   WEB_PORT   web port (default 3100; the mocked suite and dev use 3000)
#
# Both servers and the scratch store are removed on exit — success, failure,
# or Ctrl-C.
cd "$(dirname "$0")/.."
. scripts/lib.sh

API_PORT="${API_PORT:-8081}"
WEB_PORT="${WEB_PORT:-3100}"

require_tools zig bun curl lsof
require_port_free "$API_PORT" "set API_PORT or stop that server"
require_port_free "$WEB_PORT" "set WEB_PORT or stop that server"
scratch_store e2e-live

echo "e2e-live: building API ..."
(cd api && zig build)

echo "e2e-live: API on :$API_PORT, store $scratch"
start_api "$API_PORT" "$scratch_dir/api.log"

echo "e2e-live: web on :$WEB_PORT (proxying /api -> :$API_PORT)"
(cd web && PORT="$WEB_PORT" BACKEND_URL="http://127.0.0.1:$API_PORT" exec bun server.ts) > "$scratch_dir/web.log" 2>&1 &
web_pid=$!
scratch_pids+=("$web_pid")
wait_for_url "http://127.0.0.1:$WEB_PORT/" "web server" "$web_pid"

cd web
E2E_LIVE_DATA_PATH="$scratch" WEB_PORT="$WEB_PORT" \
  bun node_modules/@playwright/test/cli.js test -c playwright.live.config.ts "$@"
