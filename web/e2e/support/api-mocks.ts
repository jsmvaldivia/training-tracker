import type { Page, Route } from '@playwright/test';
import type { Milestone, Pursuit } from '../../src/types';
import { buildListResponse, fixturePursuits } from './fixtures';

// Playwright route-mock helper for the Training Tracker API. Install in a spec's
// `beforeEach` via `await mockApi(page)`; the app then renders entirely from
// mocked responses, so the E2E suite needs no live backend.
//
// Routes:
//   GET   /api/pursuits                          -> { data, total, limit, offset }
//   PATCH /api/pursuits/:id                      -> echoes the updated Pursuit
//   PATCH /api/pursuits/:id/milestones/:mid      -> echoes the updated Milestone
//
// Pass `failMutations: true` to make every mutation respond 500 — used to drive
// the optimistic-rollback + toast path (issue #4).

export interface MockApiOptions {
  // Override the pursuit list served by the list route. Defaults to the
  // relative-date fixtures sourced from `web/src/data.ts`.
  pursuits?: Pursuit[];
  // When true, mutation routes respond 500 instead of echoing the change.
  failMutations?: boolean;
}

function parseListParams(url: URL): { type?: string; limit?: number; offset?: number } {
  const type = url.searchParams.get('type') ?? undefined;
  const limitRaw = url.searchParams.get('limit');
  const offsetRaw = url.searchParams.get('offset');
  return {
    type,
    limit: limitRaw != null ? Number(limitRaw) : undefined,
    offset: offsetRaw != null ? Number(offsetRaw) : undefined,
  };
}

// Path segments after `/pursuits`: [pursuitId, ('milestones'), milestoneId].
function parsePath(url: URL): { pursuitId?: string; milestoneId?: string } {
  const parts = url.pathname.split('/');
  const idx = parts.indexOf('pursuits');
  if (idx === -1) return {};
  return { pursuitId: parts[idx + 1], milestoneId: parts[idx + 3] };
}

async function fulfill500(route: Route): Promise<void> {
  await route.fulfill({
    status: 500,
    contentType: 'application/json',
    body: JSON.stringify({ status: 500, message: 'Failed to persist change' }),
  });
}

// Echo a milestone the way the backend would: apply the patch and let the
// server "stamp" achieved_at when the state becomes achieved (cleared otherwise).
function echoMilestone(
  original: Milestone | undefined,
  milestoneId: string,
  patch: Partial<Milestone>
): Milestone {
  const base: Milestone =
    original ?? { id: milestoneId, name: 'Milestone', date: new Date().toISOString(), state: 'pending' };
  const merged: Milestone = { ...base, ...patch, id: milestoneId };
  if (merged.state === 'achieved') {
    merged.achieved_at = merged.achieved_at ?? new Date().toISOString();
  } else {
    delete merged.achieved_at;
  }
  return merged;
}

function echoPursuit(original: Pursuit | undefined, pursuitId: string, patch: Partial<Pursuit>): Pursuit {
  const merged = { ...(original as Pursuit), ...patch, id: pursuitId };
  if (merged.status === 'completed') {
    merged.completed_at = merged.completed_at ?? new Date().toISOString();
  }
  return merged;
}

export async function mockApi(page: Page, options: MockApiOptions = {}): Promise<void> {
  const pursuits = options.pursuits ?? fixturePursuits;
  const fail = options.failMutations ?? false;

  // GET /api/pursuits (with optional ?type=&limit=&offset=)
  await page.route('**/api/pursuits*', async (route: Route) => {
    if (route.request().method() !== 'GET') {
      // Mutations are claimed by the more specific routes registered below.
      await route.fallback();
      return;
    }
    const url = new URL(route.request().url());
    const body = buildListResponse(pursuits, parseListParams(url));
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });

  // PATCH /api/pursuits/:id  -> full Pursuit
  await page.route('**/api/pursuits/*', async (route: Route) => {
    if (route.request().method() !== 'PATCH') {
      await route.fallback();
      return;
    }
    if (fail) {
      await fulfill500(route);
      return;
    }
    const url = new URL(route.request().url());
    const { pursuitId } = parsePath(url);
    const patch = (route.request().postDataJSON() ?? {}) as Partial<Pursuit>;
    const original = pursuits.find((p) => p.id === pursuitId);
    const body = echoPursuit(original, pursuitId ?? '', patch);
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });

  // PATCH /api/pursuits/:id/milestones/:mid  -> single Milestone.
  // Registered last so it takes precedence over the pursuit-item route for this URL.
  await page.route('**/api/pursuits/*/milestones/*', async (route: Route) => {
    if (route.request().method() !== 'PATCH') {
      await route.fallback();
      return;
    }
    if (fail) {
      await fulfill500(route);
      return;
    }
    const url = new URL(route.request().url());
    const { pursuitId, milestoneId } = parsePath(url);
    const patch = (route.request().postDataJSON() ?? {}) as Partial<Milestone>;
    const original = pursuits
      .find((p) => p.id === pursuitId)
      ?.milestones.find((m) => m.id === milestoneId);
    const body = echoMilestone(original, milestoneId ?? '', patch);
    await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });
}
