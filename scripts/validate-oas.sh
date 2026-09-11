#!/usr/bin/env bash
set -euo pipefail

# Lint the OpenAPI contract with Spectral. The ruleset, the runner, and the
# fail severity live here and nowhere else.
cd "$(dirname "$0")/.."

CLI="web/node_modules/@stoplight/spectral-cli/dist/index.js"
[[ -f "$CLI" ]] || { echo "error: Spectral missing. Run mise exec -- ./scripts/setup.sh." >&2; exit 1; }

exec bun "$CLI" lint api/openapi.yaml --ruleset api/.spectral.yaml --fail-severity warn
