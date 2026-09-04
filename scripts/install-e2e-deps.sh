#!/usr/bin/env bash
set -euo pipefail

# Claude remote sessions use the same explicit setup as other agents.
# The pinned tools must already be on PATH (or launch Claude via mise exec).
cd "$(dirname "$0")/.."

# Cloud sessions only — local machines manage their own browsers.
if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

exec ./scripts/setup.sh
