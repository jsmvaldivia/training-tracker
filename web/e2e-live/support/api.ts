import { expect } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { Milestone, Pursuit } from '../../src/types';

// Helpers for the live suite: talk to the real API through the Bun proxy
// (`/api/*`, same origin as the page) to seed data and to confirm what the
// store holds after a UI action. Every seeded record gets a unique name so
// reruns and the seed pursuits never collide.

export const seed = JSON.parse(
  readFileSync(resolve(__dirname, '../../../api/data.seed.json'), 'utf8')
) as { pursuits: Pursuit[] };

export function uniqueName(prefix: string): string {
  return `${prefix} ${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}

export interface SeedPursuit {
  name: string;
  type?: Pursuit['type'];
  status?: Pursuit['status'];
  started_at?: string;
  target_date?: string;
  expires_at?: string;
  milestones?: Array<{ name: string; date: string; state?: Milestone['state'] }>;
}

export async function createPursuit(request: APIRequestContext, body: SeedPursuit): Promise<Pursuit> {
  const response = await request.post('/api/pursuits', {
    data: {
      type: 'training',
      status: 'planned',
      started_at: '2026-06-01T00:00:00Z',
      target_date: '2026-12-31T00:00:00Z',
      ...body,
    },
  });
  expect(response.status(), await response.text()).toBe(201);
  return (await response.json()) as Pursuit;
}

export async function getPursuit(request: APIRequestContext, id: string): Promise<Pursuit> {
  const response = await request.get(`/api/pursuits/${id}`);
  expect(response.status(), await response.text()).toBe(200);
  return (await response.json()) as Pursuit;
}
