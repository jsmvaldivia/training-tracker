#!/usr/bin/env bash
set -euo pipefail

# API performance snapshot (issue #35): startup time, throughput, memory, and
# binary size for the Zig API. Builds ReleaseSafe (never benchmark a Debug
# build: its DebugAllocator distorts everything), starts the binary on a
# scratch copy of the seed, and drives it with oha.
#
#   scripts/bench.sh          human-readable table
#   scripts/bench.sh --json   one JSON object on stdout (for perf-snapshot.sh)
#
#   PORT            spare port for the scratch server (default 8086)
#   BENCH_REQUESTS  requests per load (default 2000)
#
# Loads:
#   read   GET /pursuits, 16 connections, --disable-keepalive — the server
#          answers one request per connection (keep_alive=false), so that is
#          the real shape.
#   write  PATCH /pursuits/p_1/milestones/m_1 with -c 1 — the store is not
#          thread-safe and the accept loop is serial; more connections would
#          only measure queueing.
# Each load is a fixed request count, not a duration: one connection per
# request burns an ephemeral port per request, and a timed run at this rate
# exhausts macOS's ~16k ports (TIME_WAIT) within seconds, after which the
# numbers measure the kernel, not the server.
# Memory: RSS after ready and after each load. The write run grows it — the
# store arena keeps every mutation until restart (store.zig, `list` doc);
# that is the baseline the SQLite migration should lower. Idle RSS carries
# ~1.1 MiB of fixed per-connection stack buffers from main.zig, by design.
#
# Runnable from anywhere — resolves paths relative to the repo root.
cd "$(dirname "$0")/.."

PORT="${PORT:-8086}"
REQUESTS="${BENCH_REQUESTS:-2000}"
JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

for tool in zig oha curl jq python3 ps; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 2; }
done
if lsof -i ":$PORT" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
  echo "error: port $PORT is held; set PORT to a free one" >&2
  exit 2
fi

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/tt-bench.XXXXXX")"
scratch="$scratch_dir/data.json"
cp api/data.seed.json "$scratch"
pid=""
cleanup() {
  local status=$?
  [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  rm -rf "$scratch_dir"
  exit "$status"
}
trap cleanup EXIT INT TERM

now_ns() { python3 -c 'import time; print(time.time_ns())'; }
rss_kb() { ps -o rss= -p "$1" | tr -d ' '; }
file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

(cd api && zig build -Doptimize=ReleaseSafe) >&2
binary=api/zig-out/bin/training-tracker
binary_bytes=$(file_size "$binary")

# ---- startup: wall time from spawn to the first /health 200 ------------------
# Three starts; the first pays the page-in of a freshly built binary (~150 ms
# on macOS versus ~20 ms warm) and every gate run builds fresh, so it is kept
# as startup_cold_ms for information and the best of three is the metric.
start_api() {
  PORT="$PORT" DATA_PATH="$scratch" "$binary" > "$scratch_dir/api.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 300); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then return 0; fi
    kill -0 "$pid" 2>/dev/null || { echo "error: API exited during startup" >&2; cat "$scratch_dir/api.log" >&2; return 1; }
    sleep 0.01
  done
  echo "error: API not ready on :$PORT" >&2
  return 1
}
stop_api() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pid=""
}
startup_wall_ms=""
startup_cold_ms=""
for attempt in 1 2 3; do
  t0=$(now_ns)
  start_api
  t1=$(now_ns)
  ms=$(( (t1 - t0) / 1000000 ))
  [[ $attempt -eq 1 ]] && startup_cold_ms=$ms
  if [[ -z "$startup_wall_ms" || $ms -lt $startup_wall_ms ]]; then startup_wall_ms=$ms; fi
  [[ $attempt -lt 3 ]] && stop_api
done
# The server's own measure (store load → listen), from its log line.
startup_store_ms=$(grep -o 'startup [0-9.]* ms' "$scratch_dir/api.log" | grep -o '[0-9.]*' | head -1)
startup_store_ms="${startup_store_ms:-0}"
rss_idle_kb=$(rss_kb "$pid")

# ---- read load ----------------------------------------------------------------
oha --no-tui --output-format json -n "$REQUESTS" -c 16 --disable-keepalive \
  "http://127.0.0.1:$PORT/pursuits" > "$scratch_dir/read.json"
rss_after_read_kb=$(rss_kb "$pid")

# ---- write load ---------------------------------------------------------------
oha --no-tui --output-format json -n "$REQUESTS" --disable-keepalive -c 1 \
  -m PATCH -H 'content-type: application/json' -d '{"state":"achieved"}' \
  "http://127.0.0.1:$PORT/pursuits/p_1/milestones/m_1" > "$scratch_dir/write.json"
rss_after_write_kb=$(rss_kb "$pid")

platform="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Compact: perf-snapshot.sh appends this as one JSONL line.
snapshot=$(jq -c -n \
  --arg timestamp "$timestamp" --arg commit "$commit" --arg platform "$platform" \
  --argjson requests "$REQUESTS" \
  --argjson startup_wall_ms "$startup_wall_ms" --argjson startup_cold_ms "$startup_cold_ms" \
  --argjson startup_store_ms "$startup_store_ms" \
  --argjson rss_idle_kb "$rss_idle_kb" --argjson rss_after_read_kb "$rss_after_read_kb" \
  --argjson rss_after_write_kb "$rss_after_write_kb" --argjson binary_bytes "$binary_bytes" \
  --slurpfile read "$scratch_dir/read.json" --slurpfile write "$scratch_dir/write.json" \
  '{
    timestamp: $timestamp, commit: $commit, platform: $platform, requests: $requests,
    startup_wall_ms: $startup_wall_ms, startup_cold_ms: $startup_cold_ms, startup_store_ms: $startup_store_ms,
    read_rps: ($read[0].summary.requestsPerSec | . * 10 | round / 10),
    read_p50_ms: ($read[0].latencyPercentiles.p50 * 1000 | . * 100 | round / 100),
    read_p99_ms: ($read[0].latencyPercentiles.p99 * 1000 | . * 100 | round / 100),
    read_non_2xx: ($read[0].statusCodeDistribution | to_entries | map(select(.key | startswith("2") | not) | .value) | add // 0),
    write_rps: ($write[0].summary.requestsPerSec | . * 10 | round / 10),
    write_p50_ms: ($write[0].latencyPercentiles.p50 * 1000 | . * 100 | round / 100),
    write_p99_ms: ($write[0].latencyPercentiles.p99 * 1000 | . * 100 | round / 100),
    write_non_2xx: ($write[0].statusCodeDistribution | to_entries | map(select(.key | startswith("2") | not) | .value) | add // 0),
    rss_idle_kb: $rss_idle_kb, rss_after_read_kb: $rss_after_read_kb, rss_after_write_kb: $rss_after_write_kb,
    binary_bytes: $binary_bytes
  }')

if (( JSON )); then
  echo "$snapshot"
else
  echo "$snapshot" | jq -r '
    "API performance snapshot — \(.platform) @ \(.commit), \(.requests) requests per load",
    "  startup      \(.startup_wall_ms) ms wall (best of 3, spawn → /health; cold \(.startup_cold_ms) ms), \(.startup_store_ms) ms store load → listen",
    "  read  GET    \(.read_rps) req/s  p50 \(.read_p50_ms) ms  p99 \(.read_p99_ms) ms  non-2xx \(.read_non_2xx)",
    "  write PATCH  \(.write_rps) req/s  p50 \(.write_p50_ms) ms  p99 \(.write_p99_ms) ms  non-2xx \(.write_non_2xx)",
    "  rss          idle \(.rss_idle_kb) KiB → after read \(.rss_after_read_kb) KiB → after write \(.rss_after_write_kb) KiB",
    "  binary       \(.binary_bytes) bytes (ReleaseSafe)"'
fi
