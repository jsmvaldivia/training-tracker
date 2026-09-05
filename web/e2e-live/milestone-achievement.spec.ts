import { test, expect } from '@playwright/test';
import { createPursuit, getPursuit, uniqueName } from './support/api';

// Issue #10: toggling a milestone persists its state and achieved_at through
// the real API, and the achieved count in the panel follows.

test('milestone achievement persists and updates progress', async ({ page, request }) => {
  const name = uniqueName('Milestones');
  const created = await createPursuit(request, {
    name,
    status: 'in_progress',
    milestones: [
      { name: 'First step', date: '2026-07-01T00:00:00Z' },
      { name: 'Second step', date: '2026-08-01T00:00:00Z' },
    ],
  });
  const milestoneId = created.milestones[0].id;
  const storedFirst = async () => (await getPursuit(request, created.id)).milestones.find((m) => m.id === milestoneId)!;

  await page.goto('/');
  await page.locator('div.cursor-pointer').filter({ hasText: name }).first().click();
  const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
  await expect(panel.locator('text=/0\\s*\\/\\s*2/')).toBeVisible();

  await panel.getByText('First step').click();
  await expect(panel.locator('text=/1\\s*\\/\\s*2/')).toBeVisible();
  await expect.poll(async () => (await storedFirst()).state).toBe('achieved');
  expect((await storedFirst()).achieved_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);

  await panel.getByText('First step').click();
  await expect(panel.locator('text=/0\\s*\\/\\s*2/')).toBeVisible();
  await expect.poll(async () => (await storedFirst()).state).toBe('pending');
  expect((await storedFirst()).achieved_at).toBeUndefined();
});
