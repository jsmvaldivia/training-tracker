import type { Page, Route } from '@playwright/test';
import type { Pursuit } from '../../src/types';
import { buildListResponse, fixturePursuits } from './fixtures';

// Playwright route-mock helper for the Training Tracker API. Install in a spec's
// `beforeEach` via `await mockApi(page)`; the app then renders entirely from
// mocked responses, so the E2E suite needs no live backend.
//
// Issue #3 wires only the READ path: `GET /api/pursuits` returns the list
// envelope `{ data, total, limit, offset }`, honoring `type` / `limit` /
// `offset` query params. Mutation routes (PATCH milestones / pursuits) belong to
// issue #4 — extend `mockApi` there.

export interface MockApiOptions {
  // Override the pursuit list served by the list route. Defaults to the
  // relative-date fixtures sourced from `web/src/data.ts`.
  pursuits?: Pursuit[];
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

export async function mockApi(page: Page, options: MockApiOptions = {}): Promise<void> {
  const pursuits = options.pursuits ?? fixturePursuits;

  // GET /api/pursuits (with optional ?type=&limit=&offset=)
  await page.route('**/api/pursuits*', async (route: Route) => {
    if (route.request().method() !== 'GET') {
      // Out of scope for the read path (issue #3); let it fall through so a
      // future mutation mock (issue #4) can claim it.
      await route.fallback();
      return;
    }

    const url = new URL(route.request().url());
    const body = buildListResponse(pursuits, parseListParams(url));

    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(body),
    });
  });
}
