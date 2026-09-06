import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { mockApi } from './support/api-mocks';

// Issue #22: add and delete milestones in the detail panel. Both are
// optimistic — the list and the achieved count change at once — and a failed
// request rolls back with a toast.

const AWS = 'AWS Certified Solutions Architect';

async function openAws(page: Page) {
  await page.locator('div.cursor-pointer').filter({ hasText: AWS }).first().click();
  await expect(page.getByRole('heading', { name: 'Milestones' })).toBeVisible({ timeout: 3000 });
  return page.locator('[class*="fixed"][class*="right-0"]').first();
}

test.describe('Milestones — add and delete', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('adds a milestone and bumps the total', async ({ page }) => {
    const panel = await openAws(page);
    await expect(panel.locator('text=/2\\s*\\/\\s*4/')).toBeVisible();

    await panel.getByLabel('Milestone name').fill('Schedule exam');
    await panel.getByLabel('Milestone date').fill('2026-08-01');
    const request = page.waitForRequest(
      (r) => r.method() === 'POST' && r.url().endsWith('/api/pursuits/p1/milestones')
    );
    await panel.getByRole('button', { name: 'Add milestone' }).click();

    expect((await request).postDataJSON()).toEqual({ name: 'Schedule exam', date: '2026-08-01T00:00:00Z' });
    await expect(panel.getByText('Schedule exam')).toBeVisible();
    await expect(panel.locator('text=/2\\s*\\/\\s*5/')).toBeVisible();
    // The form is ready for the next one.
    await expect(panel.getByLabel('Milestone name')).toHaveValue('');
  });

  test('deletes a milestone without toggling it', async ({ page }) => {
    const panel = await openAws(page);
    let patched = false;
    page.on('request', (r) => {
      if (r.method() === 'PATCH') patched = true;
    });

    const request = page.waitForRequest(
      (r) => r.method() === 'DELETE' && r.url().endsWith('/api/pursuits/p1/milestones/m4')
    );
    await panel.getByRole('button', { name: 'Delete milestone Book Exam' }).click();
    await request;

    await expect(panel.getByText('Book Exam')).toHaveCount(0);
    await expect(panel.locator('text=/2\\s*\\/\\s*3/')).toBeVisible();
    expect(patched).toBe(false);
  });
});

test.describe('Milestones — failure rolls back and toasts', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page, { failMutations: true });
    await page.goto('/');
  });

  test('a failed add removes the optimistic milestone', async ({ page }) => {
    const panel = await openAws(page);
    await panel.getByLabel('Milestone name').fill('Doomed');
    await panel.getByLabel('Milestone date').fill('2026-08-01');
    await panel.getByRole('button', { name: 'Add milestone' }).click();

    await expect(page.getByText('Failed to persist change')).toBeVisible();
    await expect(panel.getByText('Doomed')).toHaveCount(0);
    await expect(panel.locator('text=/2\\s*\\/\\s*4/')).toBeVisible();
  });

  test('a failed delete brings the milestone back', async ({ page }) => {
    const panel = await openAws(page);
    await panel.getByRole('button', { name: 'Delete milestone Book Exam' }).click();

    await expect(page.getByText('Failed to persist change')).toBeVisible();
    await expect(panel.getByText('Book Exam')).toBeVisible();
    await expect(panel.locator('text=/2\\s*\\/\\s*4/')).toBeVisible();
  });
});
