import { test, expect } from '@playwright/test';
import { format, parseISO } from 'date-fns';
import { createPursuit, getPursuit, uniqueName } from './support/api';

// Issue #9: the status lifecycle planned → in_progress → completed persists
// through the real stack. The UI has no create form, so the pursuit is seeded
// with POST /pursuits; every change is asserted in the UI and then via GET.

test('status lifecycle persists through the real API', async ({ page, request }) => {
  const name = uniqueName('Lifecycle');
  const created = await createPursuit(request, { name, status: 'planned' });

  await page.goto('/');
  await page.locator('div.cursor-pointer').filter({ hasText: name }).first().click();
  const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
  await expect(panel.getByRole('heading', { name })).toBeVisible();
  const status = panel.getByRole('combobox');
  await expect(status).toHaveValue('planned');

  await status.selectOption('in_progress');
  await expect(status).toHaveValue('in_progress');
  await expect.poll(async () => (await getPursuit(request, created.id)).status).toBe('in_progress');
  expect((await getPursuit(request, created.id)).completed_at).toBeUndefined();

  await status.selectOption('completed');
  await expect(status).toHaveValue('completed');
  await expect.poll(async () => (await getPursuit(request, created.id)).status).toBe('completed');

  const stored = await getPursuit(request, created.id);
  expect(stored.completed_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  // The reconciled server pursuit reaches the panel: its completed_at shows
  // as the Completed date (formatted the way the panel formats it).
  await expect(panel.getByText(format(parseISO(stored.completed_at!), 'MMM d, yyyy'))).toBeVisible();
});
