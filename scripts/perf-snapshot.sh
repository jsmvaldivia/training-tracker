#!/usr/bin/env bash
set -euo pipefail

# The gate's perf step (issue #35): take a snapshot with scripts/bench.sh,
# compare it with the last five snapshots taken on the same platform, and
# fail when a metric regressed by more than THRESHOLD percent against their
# median. A passing snapshot is appended to perf-snapshots.jsonl (commit it
# with the change that produced it); a failing one is printed, not recorded.
#
# Platform-scoped history: absolute numbers from a laptop and a CI runner are
# not comparable, so each host kind builds up its own baseline. Until five
# snapshots exist for a platform, the median is taken over the ones there
# are; with none, the check only reports.
#
#   PERF_THRESHOLD   percent, default 25 — tighten once the noise floor is known
#   BENCH_REQUESTS   passed through to bench.sh
cd "$(dirname "$0")/.."

HISTORY="perf-snapshots.jsonl"
THRESHOLD="${PERF_THRESHOLD:-25}"
WINDOW=5

snapshot=$(scripts/bench.sh --json)
platform=$(echo "$snapshot" | jq -r .platform)
touch "$HISTORY"

# Metrics and their direction: 1 = lower is better, -1 = higher is better.
# p50 is compared; p99 is recorded but not compared — at 2000 requests it
# swings about 30 % between identical runs, which is above the threshold.
metrics='[
  ["startup_wall_ms", 1], ["read_rps", -1], ["read_p50_ms", 1],
  ["write_rps", -1], ["write_p50_ms", 1], ["rss_idle_kb", 1], ["binary_bytes", 1]
]'

report=$(jq -n --argjson snap "$snapshot" --argjson metrics "$metrics" \
  --argjson threshold "$THRESHOLD" --argjson window "$WINDOW" --arg platform "$platform" \
  --slurpfile history <(grep -v '^\s*$' "$HISTORY" || true) '
  ($history | map(select(.platform == $platform)) | .[-$window:]) as $base
  | ($base | length) as $n
  | [ $metrics[] | .[0] as $m | .[1] as $dir
      | ($base | map(.[$m]) | sort) as $vals
      | (if $n == 0 then null
         elif ($n % 2) == 1 then $vals[($n - 1) / 2]
         else ($vals[$n / 2 - 1] + $vals[$n / 2]) / 2 end) as $median
      | ($snap[$m]) as $now
      | (if $median == null or $median == 0 then null
         else (($now - $median) / $median * 100 * $dir) end) as $worse_pct
      | { metric: $m, now: $now, median: $median, worse_pct: $worse_pct,
          regressed: ($worse_pct != null and $worse_pct > $threshold) } ]
  | { n: $n, rows: . , failed: (map(.regressed) | any) }')

echo "perf: $platform, comparing with $(echo "$report" | jq .n) earlier snapshot(s), threshold ${THRESHOLD}%"
echo "$report" | jq -r '.rows[] | "  \(.metric | . + " " * (16 - length))\(.now)\(if .median == null then "" else "  median \(.median | . * 100 | round / 100)  \(if .worse_pct > 0 then "+" else "" end)\(.worse_pct | . * 10 | round / 10)% worse\(if .regressed then "  REGRESSION" else "" end)" end)"'

if [[ "$(echo "$report" | jq .failed)" == "true" ]]; then
  echo "perf: FAILED — a metric regressed by more than ${THRESHOLD}% (snapshot not recorded)" >&2
  exit 1
fi

echo "$snapshot" >> "$HISTORY"
echo "perf: recorded in $HISTORY"
