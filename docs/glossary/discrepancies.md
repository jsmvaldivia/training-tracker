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

### Status · `expired` is never derived
- Expected: `expired` "aligns with `expires_at` passed (certifications)".
- Actual: the backend only validates `expired` as an allowed enum value.
  Nothing in `api/` or `web/` compares `expires_at` to the clock; the status
  has to be set by hand through `PATCH /pursuits/{id}`.
- Anchor: `api/src/store.zig` (statuses array), `web/src/utils.ts`
  (`calculateDerivedState` ignores `expires_at`).
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

### Tag · stored but not filterable
- Expected: a [[tag]] is "a filtering axis".
- Actual: the API accepts and persists `tags` (max 20) and the cards render
  them, but the only filter in the UI is pursuit `type`. Tag filtering is
  listed as deferred in README, so this is a scope gap rather than a bug.
- Anchor: `api/src/store.zig` (`max_tags`), `web/src/App.tsx` (`filterType`).
- Flagged by: claude-md-audit · 2026-09-03

Not discrepancies (simply unimplemented, per README "deferred"): `leads_to`,
[[plan]], [[resource]], [[renewal]].
