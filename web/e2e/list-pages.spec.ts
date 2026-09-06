import { test, expect } from '@playwright/test';
import type { Request } from '@playwright/test';
import { mockApi } from './support/api-mocks';
import { fixturePursuits } from './support/fixtures';
import type { Pursuit } from '../src/types';

// Issue #24: GET /pursuits is paged (limit ≤ 100, default 50) and the UI loads
// the whole list once, then filters in memory — so it has to walk every page.
// 120 pursuits span two pages of 100; even ids are certifications.

function manyPursuits(count: number): Pursuit[] {
  const template = fixturePursuits[0];
  return Array.from({ length: count }, (_, i) => ({
    ...template,
    id: `p_${i + 1}`,
    name: `Pursuit ${String(i + 1).padStart(3, '0')}`,
    type: i % 2 === 0 ? 'certification' : 'training',
    milestones: [],
  }));
}

function listQuery(request: Request): string | null {
  const url = new URL(request.url());
  const isList = url.pathname.endsWith('/api/pursuits') && request.method() === 'GET';
  return isList ? url.search : null;
}

test.describe('Loading the whole list', () => {
  test('loads every pursuit when the list spans more than one API page', async ({ page }) => {
    const queries: string[] = [];
    page.on('request', (request) => {
      const query = listQuery(request);
      if (query !== null) queries.push(query);
    });
    await mockApi(page, { pursuits: manyPursuits(120) });
    await page.goto('/');

    await expect(page.getByText('Total Pursuits').locator('..')).toContainText('120');
    await expect(page.getByText('Pursuit 120', { exact: true })).toBeVisible();
    await expect(page.locator('div.cursor-pointer')).toHaveCount(120);

    // Two page requests, the second past the first hundred.
    expect(queries).toHaveLength(2);
    expect(queries[0]).toContain('limit=100');
    expect(queries[1]).toContain('offset=100');
  });

  test('the type filter applies to the full list, not to one page', async ({ page }) => {
    await mockApi(page, { pursuits: manyPursuits(120) });
    await page.goto('/');
    await expect(page.locator('div.cursor-pointer')).toHaveCount(120);

    await page.getByRole('combobox').selectOption('certification');

    await expect(page.locator('div.cursor-pointer')).toHaveCount(60);
    await expect(page.getByText('Pursuit 119', { exact: true })).toBeVisible();
    await expect(page.getByText('Pursuit 120', { exact: true })).not.toBeVisible();
    // The header counts every pursuit, whatever the filter.
    await expect(page.getByText('Total Pursuits').locator('..')).toContainText('120');
  });
});
