#!/usr/bin/env bash
set -euo pipefail

# Validate the OpenAPI contract with Spectral.
# Runnable from anywhere — resolves paths relative to the repo root.
cd "$(dirname "$0")/.."

SPEC="api/openapi.yaml"
RULESET="api/.spectral.yaml"

if [[ ! -f "$RULESET" ]]; then
  echo "error: $RULESET missing — lint gate not configured" >&2
  exit 1
fi

exec bunx @stoplight/spectral-cli lint "$SPEC" \
  --ruleset "$RULESET" \
  --fail-severity warn
