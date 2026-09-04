#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-tools.sh
if [[ ! -f web/node_modules/@playwright/test/cli.js || ! -f web/node_modules/@stoplight/spectral-cli/dist/index.js ]]; then
  echo "error: test dependencies missing. Run mise exec -- ./scripts/setup.sh." >&2
  exit 1
fi

# Probe the port before running the gates. Playwright also refuses to reuse a
# server, covering a process that takes the port after this check.
bun -e '
  try {
    const server = Bun.listen({ hostname: "0.0.0.0", port: 3000, socket: { data() {} } });
    server.stop(true);
  } catch (error) {
    console.error("error: cannot bind E2E port 3000. Stop any server using it, or check local socket permissions, and retry.", error.message);
    process.exit(1);
  }
'

./scripts/validate-oas.sh
# Imported store tests occur in multiple binaries and share /tmp paths.
(cd api && zig fmt --check . && zig build test -j1)
(cd web && bun test:unit && CI=1 PORT=3000 PLAYWRIGHT_HTML_OPEN=never bun test:e2e --reporter=line)
echo "All verification gates passed."
