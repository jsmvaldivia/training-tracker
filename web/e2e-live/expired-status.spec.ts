import { test, expect } from '@playwright/test';
import { createPursuit, getPursuit, uniqueName } from './support/api';

// Issue #28: the API derives `expired` on read for a completed pursuit whose
// expires_at has passed, and the dashboard shows what the API reports. The
// rule lives in the server, so only the live suite can prove it.

test('a completed certification past its expires_at reads expired end to end', async ({ page, request }) => {
  const expiredName = uniqueName('Expired cert');
  const expired = await createPursuit(request, {
    name: expiredName,
    type: 'certification',
    status: 'completed',
    expires_at: '2020-01-01T00:00:00Z',
  });
  const validName = uniqueName('Valid cert');
  const valid = await createPursuit(request, {
    name: validName,
    type: 'certification',
    status: 'completed',
    expires_at: '2999-01-01T00:00:00Z',
  });

  // The create response and a fresh GET both carry the derived status.
  expect(expired.status).toBe('expired');
  expect((await getPursuit(request, expired.id)).status).toBe('expired');
  expect(valid.status).toBe('completed');

  await page.goto('/');
  const expiredCard = page.locator('div.cursor-pointer').filter({ hasText: expiredName }).first();
  await expect(expiredCard).toContainText('Expired');
  await expect(page.locator('div.cursor-pointer').filter({ hasText: validName }).first()).toContainText('Completed');

  await expiredCard.click();
  const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
  await expect(panel.getByRole('heading', { name: expiredName })).toBeVisible();
  await expect(panel.getByRole('combobox')).toHaveValue('expired');
});
