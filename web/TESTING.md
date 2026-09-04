# Testing Guide

## End goal

A change is safe to ship when the real stack — Zig API, JSON store, Bun proxy,
React UI — carries a user through every core flow: create a pursuit, move it
through its lifecycle, add and achieve milestones, and see progress on the
dashboard and timeline. Tests exist to prove that, cheaply and often. Every
tier below is a step toward that goal; none of them is the goal by itself.

Rule for all tiers: tests validate user workflows and contract behavior, not
implementation details. A CSS class existing or a function being called is
not a test.

## Tiers

| Tier | Command | Runs against | Speed | Status |
|---|---|---|---|---|
| 1. Backend unit + acceptance | `zig build test:unit` (in `api/`) | store and handlers in-process | ms | in place |
| 2. Backend HTTP integration | `zig build test:http` (in `api/`) | real server on a thread, temp data file | seconds | in place |
| 3. Frontend unit | `bun test:unit` | pure hooks/helpers in `src/**/*.test.ts` | ms | in place |
| 4. UI E2E, mocked API | `bun test:e2e` | Bun dev server, `/api/*` intercepted | ~10 s | in place, 51 specs |
| 5. Full-stack E2E, real API | not wired yet | Bun proxy → Zig API on a scratch store | seconds | **the gap** |

Tiers 1 and 2 prove the backend honors `api/openapi.yaml`. Tiers 3 and 4
prove the UI behaves given a contract-shaped response. Only tier 5 proves the
two halves agree. Until it exists, a contract drift between `openapi.yaml`
and the hand-written client in `src/api.ts` is caught by nobody.

## Tier 4 today: mocked E2E

Playwright starts `bun dev` itself. `e2e/support/api-mocks.ts` intercepts
`/api/*` and serves fixtures from `e2e/support/fixtures.ts`, which re-exports
the relative-date mock data in `src/data.ts`. The Zig backend is not needed.
Pass `failMutations: true` to `mockApi` to drive the rollback-and-toast path.

Spec files: `accessibility`, `dashboard`, `detail-panel`, `filters-and-views`,
`mutations`, `timeline-view`.

Keep this tier fast and deterministic. It is the tier that runs on every
change; it should never depend on the clock beyond relative fixture dates or
on a process outside Bun.

## Tier 5: what it takes

The server already supports the two overrides the tier needs:

- `PORT` selects the listen port (default 8080).
- `DATA_PATH` selects the JSON store (default `data.json`).

The Bun proxy honors `BACKEND_URL`. So a full-stack run is:

1. Copy `api/data.seed.json` to a scratch path.
2. Start the API with `PORT=8081 DATA_PATH=<scratch> zig build run`.
3. Start the web server with `BACKEND_URL=http://127.0.0.1:8081 bun dev`.
4. Run a separate Playwright project (`e2e-live/`) with no route mocks.
5. Delete the scratch file.

Design rules for the live suite when it is written:

- One scratch store per run, reset from the seed. Never point at `api/data.json`.
- Assert through the UI and then through the API (`GET /pursuits/{id}`), so
  a test proves persistence, not just an optimistic render.
- Cover the create → in_progress → completed lifecycle and milestone
  achievement end to end. Filters, timeline layout, and accessibility stay in
  tier 4; they do not need a real backend.
- Keep it small. Ten flows that exercise the real store beat a copy of the
  mocked suite.

When the store moves to SQLite, only steps 1 and 5 change: the scratch store
becomes a temp database file.

## Writing a tier 4 spec

Install the mocks in `beforeEach`, then write Given → When → Then:

```typescript
import { test, expect } from '@playwright/test';
import { mockApi } from './support/api-mocks';

test.beforeEach(async ({ page }) => {
  await mockApi(page);
});

test('user can mark a milestone as achieved', async ({ page }) => {
  // GIVEN a pursuit with pending milestones is open
  await page.goto('/');
  await page.getByText('AWS Certified Solutions Architect').first().click();
  await expect(page.getByText('Milestones')).toBeVisible();

  // WHEN the user clicks a pending milestone
  const milestone = page.getByText('Pass Practice Exam 1');
  await milestone.click();

  // THEN it renders as achieved
  await expect(milestone.locator('..')).toHaveClass(/line-through/);
});
```

Selector priority: user-facing text, then ARIA role, then `data-testid`,
then CSS classes as a last resort.

Fixture dates are built as `Date.now() ± N days`, so time-derived assertions
(overdue counts, progress) stay valid. Do not hardcode dates in specs.

## Debugging

```bash
bun test:e2e:ui       # timeline, DOM snapshots, network, console
bun test:e2e:headed   # visible browser
bun test:e2e:debug    # step debugger
```

Common failures:

- **Strict mode violation**: the text appears in more than one place. Scope
  to a container or use `{ exact: true }`.
- **Timing**: assert on content that proves the transition finished (for
  example the "Milestones" heading) rather than on the click itself.

## When a test fails

1. Check whether the UI works manually against the real stack (`./scripts/dev.sh`).
2. If the UI works, fix the selector or the wait.
3. If the UI is broken, fix the code and keep the test.
4. Never weaken an assertion to get green.

## Unit coverage gate

`bun test src` always runs with coverage (`web/bunfig.toml`, `[test]`). The run
fails when line or function coverage of the **loaded** files drops below 80%.
An `lcov` report lands in `web/coverage/` (gitignored).

Bun measures only the files a unit test imports. A file under `src/` that no
unit test loads does not appear in the report and does not lower the number.
So the threshold protects the code unit tests reach, and nothing else. Code
that only Playwright exercises (components, `App.tsx`) is checked by the
evaluator agent's diff rule instead: every changed production file must have a
changed or added test that exercises it (`docs/glossary/architecture.md`,
"coverage gate").

`scripts/gate.sh` runs this as its `unit-cov` step.
