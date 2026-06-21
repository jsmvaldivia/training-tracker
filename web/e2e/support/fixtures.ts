import { mockPursuits } from '../../src/data';
import type { Pursuit } from '../../src/types';

// Single source of truth for E2E fixture data. We deliberately re-export the
// relative-date mock builder from `web/src/data.ts` rather than re-typing the
// AWS / Kubernetes / CISSP / React content here: the dates are built as
// `Date.now() ± N days`, so time-derived assertions (overdue, At Risk / Overdue
// stat counts) stay valid against the live clock and never rot.
export const fixturePursuits: Pursuit[] = mockPursuits;

export interface PursuitsListResponse {
  data: Pursuit[];
  total: number;
  limit: number;
  offset: number;
}

// Build the list-endpoint envelope the API client expects:
// `{ data, total, limit, offset }`. Honors `type` / `limit` / `offset` query
// params so route-mocking mirrors the real backend's filtering/pagination.
export function buildListResponse(
  pursuits: Pursuit[] = fixturePursuits,
  params: { type?: string; limit?: number; offset?: number } = {}
): PursuitsListResponse {
  const filtered = params.type
    ? pursuits.filter((p) => p.type === params.type)
    : pursuits;

  const total = filtered.length;
  const offset = params.offset ?? 0;
  const limit = params.limit ?? total;
  const page = filtered.slice(offset, offset + limit);

  return { data: page, total, limit, offset };
}
