# Plan: Wire the React frontend to the REST API

Replace mock data in the Training Tracker frontend with the hand-written typed
fetch client (`web/src/api.ts`), and migrate the E2E suite to route-mocking.
Zero new npm packages. Organized into parallel waves with (mostly) disjoint
file ownership.

This plan was revised after a section-by-section design review. The four
decisions below shaped it; the rationale is preserved so the dispatching agents
inherit the *why*, not just the *what*.

## Design decisions

| # | Area | Decision | Why |
|---|------|----------|-----|
| 1 | Mutation model | **Optimistic + reconcile + rollback** | Keeps snappy UX and existing detail-panel E2E assertions; server still stamps `achieved_at`/`completed_at`, so reconcile-from-response is why we don't just trust the local guess. |
| 2 | Write boundary | **Hook owns mutations end-to-end** | Optimistic/rollback logic lives in exactly one place; panel becomes presentational; shrinks the coordination surface. |
| 3 | Fixtures + coverage | **Reuse the relative-date mock builder; add hook unit tests** | One source of truth for mock data (no rot from absolute timestamps); the now-critical reconcile/rollback logic is unit-tested. |
| 4 | Right-sizing | **Trim to what's used** | Drop delete-hardening and `refetch` — no caller exists until create/delete UI (Track O). Every shipped line has a caller and a test. |
| 5 | Error UX | **Toast (in-house, zero-dep)** | On rollback the user sees a transient toast; the hook stays UI-agnostic by taking an `onError` callback, App owns the toast render. |

## Verified ground truth

- Backend **stamps `achieved_at`/`completed_at` server-side** on lifecycle
  transitions (`api/src/store.zig:278,325,353-357`, `time_util.zig:1`). The
  frontend must therefore stop client-side stamping and reconcile from the
  response.
- **Mutation response shapes differ**: `PATCH /pursuits/{id}` returns the full
  `Pursuit`; `PATCH .../milestones/{id}` returns only the `Milestone`. Milestone
  reconcile merges one milestone into its pursuit — it does not replace the
  pursuit (`api/openapi.yaml`).
- `DELETE` endpoints return `204` with no body.
- `web/src/data.ts` builds dates as `Date.now() ± N days` (relative), and
  `calculateDerivedState` (`web/src/utils.ts:11`) computes
  `isOverdue`/`signal`/`timeProgress` against the live clock. E2E specs assert on
  that derived output (`/days overdue/i`, At Risk / Overdue stat counts) — so
  fixtures must stay relative, not absolute, or the specs rot.
- `api/data.json` does not exist in the worktree — the seed task creates it.

## Task graph

### Wave 1 (parallel)

- **T2 — `web/src/hooks/usePursuits.ts`** (reads *and* writes)
  - `fetch` on mount + `loading` / `error` / empty states.
  - `updateMilestone(pursuitId, milestoneId, patch)` and
    `updatePursuit(id, patch)`. Each: **optimistic apply → `api.*` call →
    reconcile from server response → rollback + report error on throw.**
  - On rollback, call the injected `onError(message)` callback (the hook never
    imports a toast component — it stays UI-agnostic). The list-fetch failure
    still sets the `error` state.
  - `reconcilePursuit` / `reconcileMilestone` are **private internals**, not
    exported.
  - No `refetch` unless T4 finds a concrete need.
  - **Options:** `usePursuits({ onError })`.
  - **Surface:** `{ pursuits, loading, error, updateMilestone, updatePursuit }`.

- **T-Toast — `web/src/components/Toast.tsx`** (new, in-house, zero-dep)
  - A minimal toast: `ToastProvider` + `useToast()` returning
    `{ error(message) }` (extend later if needed), rendering a transient,
    auto-dismissing, ARIA-live region (`role="status"` / `aria-live="polite"`)
    so the accessibility spec can assert it. No npm package — plain React +
    Tailwind + `setTimeout` dismissal.
  - Owns its own file, parallel-safe with T2/T3.

- **T3 — `web/e2e/support/{api-mocks,fixtures}.ts`**
  - Fixtures **import the existing `data.ts` mock builder** (relative dates) —
    do not re-type the AWS / Kubernetes / CISSP / React content.
  - Route-mock helper: list returns `{ data, total, limit, offset }`; mutation
    endpoints echo the merged object.

> ~~T1 (delete hardening)~~ — **dropped**. `deletePursuit`/`deleteMilestone`
> have no caller (create/delete UI is Track O). Defer the `response.ok` fix to
> the PR that adds a delete button, so the fix ships with its own test.

### Wave 2 (parallel, depends on Wave 1)

- **T4 — `web/src/App.tsx`** (deps: T2, T-Toast)
  - Consume `usePursuits({ onError: toast.error })`; drop the `mockPursuits`
    import; add loading/error states.
  - Mount `ToastProvider` and wire the hook's `onError` to `useToast().error`.
  - **Keep `web/src/data.ts` as an exported fixture module** — do NOT delete it;
    T3 imports it.

- **T5 — `web/src/components/PursuitDetailPanel.tsx`** (deps: T2)
  - Becomes **presentational**. Replace `toggleMilestone` / `handleStatusChange`
    (which stamp `achieved_at`/`completed_at` and mutate local state) with two
    callbacks wired to the hook's mutators:
    `onToggleMilestone(milestoneId)` and `onStatusChange(status)`.
  - No `fetch`, no client-side stamping, no rollback logic in the component.

- **T6 — `api/data.json` seed + dev script** (`scripts/dev.sh` or Makefile
  running `zig build run` + `bun dev`).

### Wave 3 (parallel, one spec file per task, depends on Wave 2)

- **T7–T11** — migrate dashboard / detail-panel / filters-and-views /
  timeline-view / accessibility specs to the T3 route-mock helper.
  - Detail-panel specs keep their instant-toggle assumption (the optimistic
    model preserves it).
  - Time-derived assertions stay valid because fixtures inherit relative dates.

### New test work

- **`web/src/hooks/usePursuits.test.ts`** — reconcile-merge (milestone →
  pursuit), optimistic toggle, and **rollback-on-rejection**.

### Track O (optional, out of scope)

Wire net-new create/delete UI. When this lands, it also adds the `response.ok`
hardening to `deletePursuit`/`deleteMilestone` **plus** the E2E coverage that
exercises it.

## Coordination contracts (pin before dispatch)

- **Hook surface:** `{ pursuits, loading, error, updateMilestone, updatePursuit }`,
  constructed via `usePursuits({ onError })`. Mutators are async, optimistic,
  self-reconciling, self-rolling-back; they report rollback failures through
  `onError(message)`.
- **Toast surface:** `ToastProvider` + `useToast() → { error(message) }`,
  rendering an `aria-live` region. App wires `onError → toast.error`.
- **Panel props:** `onToggleMilestone(milestoneId)` + `onStatusChange(status)` —
  no server objects cross this boundary.
- **Fixture shape:** list → `{ data, total, limit, offset }`; mutation endpoints
  echo the merged object; **fixture data is sourced from `web/src/data.ts`**.

## Open items to settle before dispatch

1. **`data.ts` is a shared dependency** of T3 (imports it) and T4 (stops
   importing it into `App`). File ownership is no longer fully disjoint — make
   sure no agent deletes `data.ts`.
2. ~~Optimistic-error UX~~ — **resolved: toast** (in-house, zero-dep). See
   T-Toast and decision #5. One follow-up for Wave 3: add an accessibility/E2E
   assertion that a failed mutation surfaces the toast (route-mock returns a
   500, expect the `aria-live` toast text).
