#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep versions in mise.toml as the single source of truth.
for tool in zig bun; do
  expected=$(sed -n "s/^$tool = \"\([^\"]*\)\"$/\1/p" mise.toml)
  if [[ -z "$expected" ]]; then
    echo "error: missing $tool version in mise.toml" >&2
    exit 1
  fi
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool $expected is required. Run mise install, then mise exec -- $0" >&2
    exit 1
  fi
  if [[ "$tool" == zig ]]; then
    actual=$(zig version)
  else
    actual=$(bun --version)
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "error: $tool $expected required; found $actual. Run mise install and use mise exec -- <command>." >&2
    exit 1
  fi
  echo "$tool $actual"
done
