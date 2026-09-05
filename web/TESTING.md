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
| 5. Full-stack E2E, real API | `bun test:e2e:live` | Bun proxy → Zig API on a scratch store | seconds | in place |

Tiers 1 and 2 prove the backend honors `api/openapi.yaml`. Tiers 3 and 4
prove the UI behaves given a contract-shaped response. Only tier 5 proves the
two halves agree: a contract drift between `openapi.yaml` and the
hand-written client in `src/api.ts` fails there and nowhere else.

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

## Tier 5: the live suite

`bun test:e2e:live` runs `scripts/e2e-live.sh`, which:

1. Builds the API and copies `api/data.seed.json` into a fresh temp directory.
2. Starts the API on `:8081` with `DATA_PATH` pointing at that copy.
3. Starts `bun server.ts` on `:3100` with `BACKEND_URL=http://127.0.0.1:8081`.
4. Runs `playwright.live.config.ts` (`testDir: e2e-live`, one worker, no
   `webServer`, no route mocks).
5. Stops both servers and deletes the temp directory — on success, failure,
   and Ctrl-C.

`api/data.json` is never read or written. Ports come from `API_PORT` and
`WEB_PORT`; the script refuses to start when one is held. Extra arguments go
to Playwright: `bun test:e2e:live -g lifecycle`, `bun test:e2e:live --ui`.

Specs: `smoke` (the seed renders), `status-lifecycle`, `milestone-achievement`,
and `rollback` (a real 500 — the spec makes the store directory read-only for
one request, so the API's flush fails). `e2e-live/support/api.ts` seeds and
reads records through the proxy with unique names, so every spec asserts
through the UI and then through `GET /pursuits/{id}`.

Rules:

- One scratch store per run, shared by all specs in the run. Seed what a spec
  needs with a unique name; never assume the seed is the whole store.
- Assert through the UI and then through the API, so a test proves
  persistence, not just an optimistic render.
- Keep it small. Lifecycle, persistence, and rollback flows live here;
  filters, timeline layout, and accessibility stay in tier 4.

Debugging: the HTML report lands in `playwright-report-live/`; traces are kept
on failure. `bun test:e2e:live --ui` opens the Playwright UI against the live
servers.

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
