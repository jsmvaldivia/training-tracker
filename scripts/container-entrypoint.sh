#!/usr/bin/env bash
set -euo pipefail

# Container entrypoint (issue #17): the API on localhost:8080 with its store on
# the /data volume, the Bun server on $PORT proxying /api/* to it. Either
# process exiting, or SIGTERM/SIGINT, stops both — the container's exit status
# is the first exit's status. The store is seeded on the first start only.

DATA_PATH="${DATA_PATH:-/data/data.json}"
PORT="${PORT:-3000}"
API_PORT=8080

mkdir -p "$(dirname "$DATA_PATH")"
if [[ ! -f "$DATA_PATH" ]]; then
  echo "seeding $DATA_PATH from the tracked seed ..."
  cp /app/api/data.seed.json "$DATA_PATH"
fi

api_pid=""
web_pid=""
stop() {
  trap - TERM INT
  for pid in "$web_pid" "$api_pid"; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap 'stop; exit 143' TERM
trap 'stop; exit 130' INT

PORT="$API_PORT" DATA_PATH="$DATA_PATH" training-tracker &
api_pid=$!

cd /app/web
PORT="$PORT" BACKEND_URL="http://127.0.0.1:$API_PORT" bun server.ts &
web_pid=$!

# Whichever process ends first ends the container.
status=0
wait -n "$api_pid" "$web_pid" || status=$?
stop
exit "$status"
