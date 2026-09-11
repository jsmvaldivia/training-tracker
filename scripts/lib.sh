#!/usr/bin/env bash
# Shared helpers for the scripts in this directory. Source it after
# `cd "$(dirname "$0")/.."` — every script runs from the repo root — with
# `. scripts/lib.sh`. It defines functions and runs nothing.

# Exit 2 unless every named tool is on PATH.
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 2; }
  done
}

# Exit 2 when something already listens on the port; the hint says what to do.
require_port_free() { # port hint
  if lsof -i ":$1" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
    echo "error: port $1 is held; $2" >&2
    exit 2
  fi
}

# Poll a URL until curl gets a 2xx. WAIT_TRIES × WAIT_INTERVAL bounds the wait
# (default 300 × 0.1 s); bench.sh lowers the interval to time startups. With a
# pid, stops early once that process has exited.
wait_for_url() { # url what [pid]
  local url="$1" what="$2" pid="${3:-}" _
  for _ in $(seq 1 "${WAIT_TRIES:-300}"); do
    curl -sf "$url" >/dev/null 2>&1 && return 0
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      echo "error: $what exited during startup" >&2
      return 1
    fi
    sleep "${WAIT_INTERVAL:-0.1}"
  done
  echo "error: $what did not become ready at $url" >&2
  return 1
}

# A scratch copy of the seed in its own directory, removed on exit — success,
# failure, or Ctrl-C — together with every process in scratch_pids, most
# recent first. Sets scratch_dir and scratch (the store path). The directory
# also takes the store's atomic-write temp files and the server logs; cleanup
# restores write permission first because the rollback spec makes the
# directory read-only mid-run.
scratch_pids=()
scratch_store() { # name
  scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/tt-$1.XXXXXX")"
  scratch="$scratch_dir/data.json"
  cp api/data.seed.json "$scratch"
  trap scratch_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
scratch_cleanup() {
  local status=$? i
  trap - EXIT
  trap '' INT TERM
  for ((i = ${#scratch_pids[@]} - 1; i >= 0; i--)); do
    kill -TERM "${scratch_pids[$i]}" 2>/dev/null || true
  done
  for ((i = ${#scratch_pids[@]} - 1; i >= 0; i--)); do
    wait "${scratch_pids[$i]}" 2>/dev/null || true
  done
  chmod -R u+w "$scratch_dir" 2>/dev/null || true
  rm -rf "$scratch_dir"
  exit "$status"
}

# Start the built API on the scratch store and wait for /health; sets api_pid.
# Callers build first: Debug for e2e-live, ReleaseSafe for bench and contract.
start_api() { # port log
  PORT="$1" DATA_PATH="$scratch" api/zig-out/bin/training-tracker > "$2" 2>&1 &
  api_pid=$!
  scratch_pids+=("$api_pid")
  wait_for_url "http://127.0.0.1:$1/health" "API" "$api_pid" || { cat "$2" >&2; return 1; }
}
stop_api() {
  kill "$api_pid" 2>/dev/null || true
  wait "$api_pid" 2>/dev/null || true
  api_pid=""
}
