#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-tools.sh
cd web
bun install --frozen-lockfile
bun node_modules/@playwright/test/cli.js install chromium
echo "Setup complete. Run mise exec -- ./scripts/gate.sh."
