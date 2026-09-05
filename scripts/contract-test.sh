#!/usr/bin/env bash
set -euo pipefail

# OpenAPI contract conformance (issue #36): start the API on a scratch store
# and let Schemathesis drive every operation in api/openapi.yaml against it —
# declared status codes, response schemas, content types, unsupported methods,
# and stateful link-based flows. Configuration lives in schemathesis.toml.
#
# Same script locally and in CI (.github/workflows/contract.yml). Needs zig,
# curl, and uvx (uv); Schemathesis itself is fetched at run time, pinned below,
# so the project gains no dependency.
#
#   PORT           port for the scratch server (default 8085)
#   SCHEMATHESIS   package spec for uvx (default schemathesis==4.25.2)
#
# Runnable from anywhere — resolves paths relative to the repo root.
cd "$(dirname "$0")/.."

PORT="${PORT:-8085}"
SCHEMATHESIS="${SCHEMATHESIS:-schemathesis==4.25.2}"
REPORT_DIR="${REPORT_DIR:-.gate/contract}"

for tool in zig curl uvx; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 2; }
done

scratch="$(mktemp -t tt-contract.XXXXXX).json"
cp api/data.seed.json "$scratch"

cleanup() {
  local status=$?
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$scratch" "$scratch".*.tmp
  exit "$status"
}
trap cleanup EXIT INT TERM

# Never benchmark or fuzz a Debug build: the debug allocator is slow and
# ReleaseSafe is what prod runs.
(cd api && zig build -Doptimize=ReleaseSafe)

PORT="$PORT" DATA_PATH="$scratch" api/zig-out/bin/training-tracker &
server_pid=$!

for _ in $(seq 1 100); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then echo "error: API exited during startup" >&2; exit 1; fi
  sleep 0.1
done
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null || { echo "error: API not reachable on :$PORT" >&2; exit 1; }

mkdir -p "$REPORT_DIR"
uvx --from "$SCHEMATHESIS" schemathesis run api/openapi.yaml \
  --url "http://127.0.0.1:$PORT" \
  --report junit --report-dir "$REPORT_DIR"
