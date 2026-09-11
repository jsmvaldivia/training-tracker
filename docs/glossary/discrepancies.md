# Discrepancies (code vs. intended)

Log of places where the code's actual behavior conflicts with intended/documented
behavior. The glossary itself only holds adjudicated truth; unresolved conflicts
live here.

Format per entry: term/feature · expected vs. actual · code anchor · who flagged
it · date.

---

### Pursuit · `started_at` is required by the API
- Expected: [[status]] is "independent of the dates"; a `planned` pursuit has
  not started, so `started_at` should be optional until it moves to
  `in_progress`.
- Actual: `POST /pursuits` rejects a body without `started_at`, and the
  frontend type declares it non-optional. Every pursuit carries a start date
  even while `planned`.
- Anchor: `api/src/store.zig` (`requireDateTime(in, "started_at")`),
  `web/src/types.ts` (`started_at: string`).
- Flagged by: claude-md-audit · 2026-09-03

### Timeline · bar spans `started_at → target_date`, not `→ completed_at`
- Expected: the timeline "draws each pursuit's `started_at`→`completed_at`
  span" on a `target_date` axis.
- Actual: the bar runs from `started_at` to `target_date`; `completed_at`
  only replaces the end when set. Overdue pursuits are colored, not flagged
  with a separate marker.
- Anchor: `web/src/components/TimelineView.tsx` (`startPct`, `targetPct`,
  `endPct`, `isOverdue`).
- Flagged by: claude-md-audit · 2026-09-03

Not discrepancies (simply unimplemented, per README "deferred"): `leads_to`,
[[plan]], [[resource]], [[renewal]] — tracked by issues #27, #26, #25. Also
unimplemented, no issue yet: filtering by [[tag]] (the API stores `tags` and
the cards render them; the only UI filter is pursuit `type`).
