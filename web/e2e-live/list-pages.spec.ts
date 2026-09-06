import { test, expect } from '@playwright/test';
import { createPursuit, uniqueName } from './support/api';

// Issue #24: the real API pages GET /pursuits (default 50, max 100) and the UI
// loads the whole list once. With more than one page in the store, every
// pursuit must still reach the dashboard. Runs first in the live suite (file
// order), so the later specs see the larger store too.

test('dashboard shows every pursuit when the store holds more than one page', async ({ page, request }) => {
  const names: string[] = [];
  for (let i = 0; i < 60; i += 1) {
    const name = uniqueName(`Page ${String(i + 1).padStart(2, '0')}`);
    await createPursuit(request, { name });
    names.push(name);
  }

  const list = (await (await request.get('/api/pursuits')).json()) as { total: number; data: unknown[] };
  expect(list.total).toBeGreaterThan(list.data.length); // the default page is short of the total

  await page.goto('/');
  await expect(page.getByText('Total Pursuits').locator('..')).toContainText(String(list.total));
  await expect(page.locator('div.cursor-pointer')).toHaveCount(list.total);
  await expect(page.getByText(names[0], { exact: true })).toBeVisible();
  await expect(page.getByText(names[names.length - 1], { exact: true })).toBeVisible();
});
