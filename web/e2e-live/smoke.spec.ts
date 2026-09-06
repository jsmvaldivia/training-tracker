import { test, expect } from '@playwright/test';
import { seed } from './support/api';

// Issue #8: the wiring works end to end — the dashboard renders the pursuits
// the real API loaded from the scratch copy of api/data.seed.json.

test('dashboard shows the seed pursuits from the real API', async ({ page, request }) => {
  await page.goto('/');

  for (const pursuit of seed.pursuits) {
    await expect(page.getByText(pursuit.name, { exact: true }).first()).toBeVisible();
  }

  // The store is shared by every spec in the run, so compare the Total chip
  // with what the API reports rather than with the seed's length.
  const list = (await (await request.get('/api/pursuits')).json()) as { total: number };
  expect(list.total).toBeGreaterThanOrEqual(seed.pursuits.length);
  await expect(page.getByText('Total Pursuits').locator('..')).toContainText(String(list.total));
});
