# Testing Guide

## Philosophy

Tests validate user workflows, not implementation details.

- Good: a user clicks a pursuit card and sees the detail panel.
- Bad: a CSS class exists on a div, or a specific function was called.

## Layers

| Layer | Command | What it covers |
|---|---|---|
| Unit | `bun test:unit` | pure hooks/helpers in `src/**/*.test.ts` |
| E2E | `bun test:e2e` | 51 Playwright specs in `e2e/*.spec.ts`, all passing |

E2E specs run against `bun dev` (Playwright starts it) with the API mocked at
the network layer. `e2e/support/api-mocks.ts` intercepts `/api/*` routes and
serves fixtures from `e2e/support/fixtures.ts`, which re-exports the
relative-date mock data in `src/data.ts`. The Zig backend is not needed.
Pass `failMutations: true` to `mockApi` to exercise the rollback-and-toast path.

Spec files: `accessibility`, `dashboard`, `detail-panel`, `filters-and-views`,
`mutations`, `timeline-view`.

## Writing a spec

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

1. Check whether the UI works manually.
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
