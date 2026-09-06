# Business knowledge

Domain vocabulary and rules for Training Tracker. The human is the source of
truth here. Entries are marked **asserted** until verified against code; where
the code disagrees, the conflict is logged in [discrepancies.md](discrepancies.md).
`Maps to` names the code that implements the term; `none` means the term is
not implemented yet (tracked by the issue named there).

### Pursuit
A thing you are working toward — a certification or a training — with a name, a
target date, and progress over time. The core entity of the app.
- Aliases: track
- Rules:
  - `type` ∈ {`certification`, `training`}.
  - Optional directional link `leads_to`: a training may lead to one
    certification, and **many trainings can feed one certification**.
  - Certifications can expire and require renewal (`expires_at`); trainings
    usually don't. Renewal spawns a linked follow-on pursuit — see [[renewal]].
  - Carries explicit [[status]], independent of the dates.
  - Carries its own private free-text `description`/`notes` (distinct from a
    [[plan]]).
  - May carry [[tag]]s (filtering axis) and [[resource]]s (learning material).
- Dates: `target_date` (timeline axis), `started_at`, `completed_at`, `expires_at`.
- Related: [[milestone]], [[time-progress]], [[achievement-progress]], [[plan]], [[overdue]], [[timeline]], [[status]], [[tag]], [[resource]], [[renewal]]
- Maps to: `api/openapi.yaml` (`Pursuit`, `PursuitCreate`, `PursuitUpdate`,
  `/pursuits`, `/pursuits/{id}`); `api/src/store.zig` (`Store.create`,
  `update`, `delete`, `list`, `get`); `api/src/pursuits.zig` (handlers);
  `web/src/types.ts` (`Pursuit`); `web/src/api.ts`. `leads_to` and the
  renewal link: none (issue #27).
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05 (`started_at` is required by the API — see discrepancies)

### Milestone
A named, dated mark on a Pursuit's timeline representing a checkpoint (e.g.
"passed mock exam", "booked exam"). Pending until reached, then achieved.
- Aliases: mark, checkpoint
- Rules:
  - Belongs to exactly one [[pursuit]].
  - State: `pending` | `achieved`; `achieved_at` set when reached.
  - Has its own date so it lands on the [[timeline]].
  - Achieved milestones feed [[achievement-progress]].
- Related: [[pursuit]], [[achievement-progress]], [[timeline]]
- Maps to: `api/openapi.yaml` (`Milestone`, `MilestoneCreate`, `MilestoneUpdate`,
  `/pursuits/{id}/milestones[/{milestoneId}]`); `api/src/store.zig`
  (`createMilestone`, `updateMilestone`, `deleteMilestone`; `achieved_at`
  stamped on `achieved`, cleared on `pending`); `web/src/types.ts` (`Milestone`).
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05

### Time Progress
A Pursuit's elapsed-time gauge: how much of the runway between start and
deadline has passed.
- Rules:
  - `(now − started_at) / (target_date − started_at)`, clamped 0–100%.
  - 0% before `started_at`; 100% when `completed_at` is set.
  - Past `target_date` and not completed → clamped at 100% and flagged [[overdue]]
    (never shown above 100%).
- Related: [[pursuit]], [[achievement-progress]], [[overdue]]
- Maps to: derived, not stored — `web/src/utils.ts` (`calculateDerivedState`,
  `timeProgress`); rendered by `web/src/components/ProgressBars.tsx`.
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05

### Achievement Progress
A Pursuit's actual-completion gauge: the share of milestones reached.
- Rules:
  - `achieved milestones ÷ total milestones`, 0–100%.
  - No milestones → 0% until `completed_at`, then 100%.
  - Read **against** [[time-progress]]: time ahead of achievement = behind
    schedule; achievement ahead of time = ahead. The gap is the key dashboard
    signal.
- Related: [[pursuit]], [[milestone]], [[time-progress]]
- Maps to: derived, not stored — `web/src/utils.ts` (`calculateDerivedState`,
  `achievementProgress`, and the `signal` gap: behind above 15 points, ahead
  below −15); rendered by `web/src/components/ProgressBars.tsx` and the
  card badge in `web/src/components/PursuitCard.tsx`.
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05

### Overdue
State of a Pursuit (or Milestone) past its `target_date` without completion.
- Rules: surfaced as a flag / red marker on the [[timeline]]; [[time-progress]]
  clamps at 100% rather than exceeding it.
- Related: [[pursuit]], [[time-progress]], [[timeline]]
- Maps to: derived — pursuits: `web/src/utils.ts` (`calculateDerivedState`,
  `isOverdue`), rendered on the card, the panel, and the timeline bar;
  milestones: `isMilestoneOverdue` in the same file (issue #29).
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05

### Plan
A titled, free-text (markdown) document capturing strategy and notes that span
several pursuits (e.g. "2026 Cloud Career Plan").
- Rules:
  - **Many-to-many** with [[pursuit]]: one plan references many pursuits; one
    pursuit can appear in many plans.
  - Distinct from a Pursuit's own private `description`/`notes`, which belongs to
    a single pursuit.
- Related: [[pursuit]]
- Maps to: none (issue #26 — concept to be confirmed before spec work)
Source: jsmvaldivia, 2026-06-16 · asserted

### Timeline
The primary view: all pursuits and their milestones laid out along time.
- Rules:
  - Axis is `target_date`.
  - Draws each pursuit's `started_at`→`completed_at` span.
  - Shows [[milestone]] marks and [[overdue]] flags.
- Related: [[pursuit]], [[milestone]], [[overdue]]
- Maps to: `web/src/components/TimelineView.tsx` (bar `started_at` →
  `target_date`, `completed_at` replaces the end when set — see discrepancies;
  milestone markers; today marker).
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05 (span rule differs — see discrepancies)

### Status
The explicit lifecycle state of a [[pursuit]], independent of (but consistent
with) its dates.
- Aliases: state
- Rules:
  - One of `planned` → `in_progress` → `completed` → `expired`.
  - `in_progress` aligns with `started_at` set; `completed` with `completed_at`
    set; `expired` with `expires_at` passed (certifications).
  - Drives queries and the [[timeline]]; the source of truth for "where is this".
- Related: [[pursuit]], [[renewal]], [[overdue]]
- Maps to: `api/openapi.yaml` (`Status` enum); `api/src/store.zig` (`statuses`;
  `completed_at` stamped on the transition to `completed`); `web/src/types.ts`
  (`PursuitStatus`); the dropdown in `web/src/components/PursuitDetailPanel.tsx`.
  `expired` is accepted, never derived — see discrepancies (issue #28).
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05 (`expired` rule not implemented — see discrepancies)

### Tag
A lightweight label on a [[pursuit]] for filtering and grouping (e.g. `cloud`,
`kubernetes`, `security`).
- Rules:
  - A pursuit may have many tags; a tag spans many pursuits (many-to-many).
  - A **filtering** axis — distinct from a [[plan]] (narrative) and a
    [[milestone]] (checkpoint).
- Related: [[pursuit]], [[plan]]
- Maps to: `api/openapi.yaml` (`tags`, max 20 of 1–50 characters);
  `api/src/store.zig` (`parseTags`); rendered by `web/src/components/PursuitCard.tsx`
  and the detail panel. Filtering by tag: none — see discrepancies.
Source: jsmvaldivia, 2026-06-16 · verified against code 2026-09-05 (not filterable — see discrepancies)

### Resource
A piece of learning material attached to a [[pursuit]] (course, book, lab,
article).
- Rules:
  - Belongs to a pursuit; fields: title, URL (optional), `consumed` flag.
  - Distinct from a [[milestone]] (a resource is material; a milestone is a
    checkpoint) — though finishing a resource may correspond to a milestone.
- Related: [[pursuit]], [[milestone]]
- Maps to: none (issue #25 — spec first with `oas-designer`, then implement)
Source: jsmvaldivia, 2026-06-16 · asserted

### Renewal
The act of renewing an expiring certification by creating a **new** [[pursuit]]
linked back to the original.
- Rules:
  - A renewal is a follow-on pursuit, not an in-place reset — the original's
    history and timeline span are preserved.
  - Linked via the same `leads_to`/predecessor mechanism so the chain is
    traceable.
  - Typically triggered as `expires_at` approaches; the original moves to
    [[status]] `expired`.
- Related: [[pursuit]], [[status]], [[overdue]]
- Maps to: none (issue #27 — `leads_to` and a renew action are absent from the
  spec; depends on the `expired` rule, issue #28)
Source: jsmvaldivia, 2026-06-16 · asserted
