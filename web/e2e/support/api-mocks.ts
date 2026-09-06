import type { Page, Route } from '@playwright/test';
import type { Milestone, Pursuit } from '../../src/types';
import { buildListResponse, fixturePursuits } from './fixtures';

// Playwright route-mock helper for the Training Tracker API. Install in a spec's
// `beforeEach` via `await mockApi(page)`; the app then renders entirely from
// mocked responses, so the E2E suite needs no live backend.
//
// Routes:
//   GET    /api/pursuits                          -> { data, total, limit, offset }
//   POST   /api/pursuits                          -> echoes a new Pursuit (id p_new_<n>)
//   PATCH  /api/pursuits/:id                      -> echoes the updated Pursuit
//   DELETE /api/pursuits/:id                      -> 204
//   POST   /api/pursuits/:id/milestones           -> echoes a new Milestone (id m_new_<n>)
//   PATCH  /api/pursuits/:id/milestones/:mid      -> echoes the updated Milestone
//   DELETE /api/pursuits/:id/milestones/:mid      -> 204
//
// The mocks are stateless: the list route always serves the fixtures, and
// mutations echo what the backend would return. That is enough because the UI
// keeps its own list state after a mutation (issues #4, #20-#23).
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

// What `POST /pursuits` returns: server-assigned id, defaults applied, inline
// milestones given ids. Read-only fields sent by the client are ignored.
let created = 0;
function echoCreatedPursuit(body: Record<string, unknown>): Pursuit {
  created += 1;
  const milestones = ((body.milestones as Partial<Milestone>[] | undefined) ?? []).map((m, i) => ({
    id: `m_new_${created}_${i}`,
    name: m.name ?? 'Milestone',
    date: m.date ?? new Date().toISOString(),
    state: m.state ?? 'pending',
  })) as Milestone[];
  const status = (body.status as Pursuit['status'] | undefined) ?? 'planned';
  const pursuit: Pursuit = {
    id: `p_new_${created}`,
    name: String(body.name ?? ''),
    type: body.type as Pursuit['type'],
    status,
    target_date: String(body.target_date ?? ''),
    started_at: String(body.started_at ?? ''),
    tags: (body.tags as string[] | undefined) ?? [],
    milestones,
  };
  if (typeof body.description === 'string') pursuit.description = body.description;
  if (typeof body.expires_at === 'string') pursuit.expires_at = body.expires_at;
  if (status === 'completed') pursuit.completed_at = new Date().toISOString();
  return pursuit;
}

function echoCreatedMilestone(body: Record<string, unknown>): Milestone {
  created += 1;
  const state = (body.state as Milestone['state'] | undefined) ?? 'pending';
  const milestone: Milestone = {
    id: `m_new_${created}`,
    name: String(body.name ?? ''),
    date: String(body.date ?? ''),
    state,
  };
  if (state === 'achieved') milestone.achieved_at = new Date().toISOString();
  return milestone;
}

async function fulfillJson(route: Route, status: number, body: unknown): Promise<void> {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

export async function mockApi(page: Page, options: MockApiOptions = {}): Promise<void> {
  const pursuits = options.pursuits ?? fixturePursuits;
  const fail = options.failMutations ?? false;

  // /api/pursuits: GET list (?type=&limit=&offset=), POST create.
  await page.route('**/api/pursuits*', async (route: Route) => {
    const method = route.request().method();
    if (method === 'GET') {
      const url = new URL(route.request().url());
      await fulfillJson(route, 200, buildListResponse(pursuits, parseListParams(url)));
      return;
    }
    if (method === 'POST') {
      if (fail) return fulfill500(route);
      const body = (route.request().postDataJSON() ?? {}) as Record<string, unknown>;
      await fulfillJson(route, 201, echoCreatedPursuit(body));
      return;
    }
    await route.fallback();
  });

  // /api/pursuits/:id: PATCH echoes the full Pursuit, DELETE answers 204.
  await page.route('**/api/pursuits/*', async (route: Route) => {
    const method = route.request().method();
    if (method !== 'PATCH' && method !== 'DELETE') {
      await route.fallback();
      return;
    }
    if (fail) return fulfill500(route);
    if (method === 'DELETE') {
      await route.fulfill({ status: 204 });
      return;
    }
    const url = new URL(route.request().url());
    const { pursuitId } = parsePath(url);
    const patch = (route.request().postDataJSON() ?? {}) as Partial<Pursuit>;
    const original = pursuits.find((p) => p.id === pursuitId);
    await fulfillJson(route, 200, echoPursuit(original, pursuitId ?? '', patch));
  });

  // /api/pursuits/:id/milestones: POST echoes the new Milestone.
  await page.route('**/api/pursuits/*/milestones', async (route: Route) => {
    if (route.request().method() !== 'POST') {
      await route.fallback();
      return;
    }
    if (fail) return fulfill500(route);
    const body = (route.request().postDataJSON() ?? {}) as Record<string, unknown>;
    await fulfillJson(route, 201, echoCreatedMilestone(body));
  });

  // /api/pursuits/:id/milestones/:mid: PATCH echoes the Milestone, DELETE 204.
  // Registered last so it takes precedence over the pursuit-item route for this URL.
  await page.route('**/api/pursuits/*/milestones/*', async (route: Route) => {
    const method = route.request().method();
    if (method !== 'PATCH' && method !== 'DELETE') {
      await route.fallback();
      return;
    }
    if (fail) return fulfill500(route);
    if (method === 'DELETE') {
      await route.fulfill({ status: 204 });
      return;
    }
    const url = new URL(route.request().url());
    const { pursuitId, milestoneId } = parsePath(url);
    const patch = (route.request().postDataJSON() ?? {}) as Partial<Milestone>;
    const original = pursuits
      .find((p) => p.id === pursuitId)
      ?.milestones.find((m) => m.id === milestoneId);
    await fulfillJson(route, 200, echoMilestone(original, milestoneId ?? '', patch));
  });
}
