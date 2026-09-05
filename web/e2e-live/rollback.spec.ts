import { test, expect } from '@playwright/test';
import { chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import { createPursuit, getPursuit, uniqueName } from './support/api';

// Issue #11: the optimistic rollback and toast against a genuine 5xx, not the
// mocked failMutations path. Trigger: the store persists by writing a temp
// file next to data.json and renaming it over, so making the scratch
// directory read-only makes the next PATCH fail its flush and answer 500.
// scripts/e2e-live.sh puts the store in a directory of its own for this.

test('a real 5xx from the API rolls back the change and toasts', async ({ page, request }) => {
  const dataPath = process.env.E2E_LIVE_DATA_PATH;
  test.skip(!dataPath, 'E2E_LIVE_DATA_PATH is set by scripts/e2e-live.sh');
  const storeDir = dirname(dataPath!);

  const name = uniqueName('Rollback');
  const created = await createPursuit(request, { name, status: 'planned' });

  await page.goto('/');
  await page.locator('div.cursor-pointer').filter({ hasText: name }).first().click();
  const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
  const status = panel.getByRole('combobox');
  await expect(status).toHaveValue('planned');

  chmodSync(storeDir, 0o555);
  try {
    const response = page.waitForResponse((r) => r.request().method() === 'PATCH');
    await status.selectOption('in_progress');
    expect((await response).status()).toBe(500);

    await expect(page.getByText('Failed to persist change')).toBeVisible();
    await expect(status).toHaveValue('planned');
    expect((await getPursuit(request, created.id)).status).toBe('planned');
  } finally {
    // Undo the trigger so later specs in the run still persist.
    chmodSync(storeDir, 0o755);
  }

  // Proof the trigger is gone: the same change now sticks.
  await status.selectOption('in_progress');
  await expect(status).toHaveValue('in_progress');
  await expect.poll(async () => (await getPursuit(request, created.id)).status).toBe('in_progress');
});
