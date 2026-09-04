#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-tools.sh
cd web
bun install --frozen-lockfile
if ! bun node_modules/@playwright/test/cli.js install chromium; then
  echo "error: Chromium installation failed. Check network access to Playwright's download hosts and rerun setup." >&2
  exit 1
fi
echo "Setup complete. Run mise exec -- ./scripts/verify.sh."
