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
#   scripts/contract-test.sh [schemathesis args...]   e.g. --seed 123 to replay a CI run
#
#   PORT           port for the scratch server (default 8085)
#   SCHEMATHESIS   package spec for uvx (default schemathesis==4.25.2)
cd "$(dirname "$0")/.."
. scripts/lib.sh

PORT="${PORT:-8085}"
SCHEMATHESIS="${SCHEMATHESIS:-schemathesis==4.25.2}"
REPORT_DIR="${REPORT_DIR:-.gate/contract}"

require_tools zig curl uvx
scratch_store contract

# ReleaseSafe is what prod runs, and a Debug build's allocator is slow.
(cd api && zig build -Doptimize=ReleaseSafe)
start_api "$PORT" "$scratch_dir/api.log"

mkdir -p "$REPORT_DIR"
uvx --from "$SCHEMATHESIS" schemathesis run api/openapi.yaml \
  --url "http://127.0.0.1:$PORT" \
  --report junit --report-dir "$REPORT_DIR" \
  "$@"
