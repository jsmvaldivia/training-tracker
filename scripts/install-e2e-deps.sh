#!/usr/bin/env bash
set -euo pipefail

# Prepare the frontend E2E test environment (cloud sessions only).
#
# Installs web/ dependencies and the Playwright Chromium browser so that
# `bun run test:e2e` can run without manual setup. The Chromium download needs
# `cdn.playwright.dev` on the environment's network allowlist (Custom access);
# without it the download is blocked by the security proxy.
#
# Runnable from anywhere — resolves paths relative to the repo root.
cd "$(dirname "$0")/.."

# Cloud sessions only — local machines manage their own browsers.
if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

cd web

# Install JS deps if they're not already present (cache makes this a no-op
# on warm sessions).
if [[ ! -d node_modules/@playwright ]]; then
  bun install
fi

# Install the Chromium browser. `playwright install` is idempotent — it skips
# the download when the browser is already cached. Tolerate failure so a blocked
# download (host not allowlisted) doesn't abort the whole session.
bunx playwright install chromium || \
  echo "warn: playwright chromium install failed — allowlist cdn.playwright.dev" >&2
