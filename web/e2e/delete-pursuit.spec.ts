import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { mockApi } from './support/api-mocks';

// Issue #21: delete a pursuit from the detail panel, with confirmation. The
// removal is optimistic: the panel closes and the card disappears at once,
// and a failed DELETE brings the card back with a toast.

const AWS = 'AWS Certified Solutions Architect';

async function openAws(page: Page) {
  await page.locator('div.cursor-pointer').filter({ hasText: AWS }).first().click();
  await expect(page.getByRole('heading', { name: 'Milestones' })).toBeVisible({ timeout: 3000 });
  return page.locator('[class*="fixed"][class*="right-0"]').first();
}

test.describe('Delete pursuit', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('asks for confirmation, then removes the pursuit', async ({ page }) => {
    const panel = await openAws(page);
    await panel.getByRole('button', { name: 'Delete pursuit' }).click();

    // Nothing is sent until the user confirms.
    await expect(panel.getByText(/cannot be undone/i)).toBeVisible();
    const request = page.waitForRequest((r) => r.method() === 'DELETE' && r.url().endsWith('/api/pursuits/p1'));
    await panel.getByRole('button', { name: 'Delete', exact: true }).click();
    await request;

    await expect(panel).toBeHidden();
    await expect(page.getByText(AWS)).toHaveCount(0);
    await expect(page.getByText('Total Pursuits').locator('..')).toContainText('3');
  });

  test('cancel keeps the pursuit and the panel open', async ({ page }) => {
    const panel = await openAws(page);
    await panel.getByRole('button', { name: 'Delete pursuit' }).click();
    await panel.getByRole('button', { name: 'Cancel', exact: true }).click();

    await expect(panel.getByText(/cannot be undone/i)).toHaveCount(0);
    await expect(panel.getByRole('heading', { name: AWS })).toBeVisible();
    await expect(page.getByText('Total Pursuits').locator('..')).toContainText('4');
  });
});

test.describe('Delete pursuit — failure', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page, { failMutations: true });
    await page.goto('/');
  });

  test('a failed delete restores the card and shows a toast', async ({ page }) => {
    const panel = await openAws(page);
    await panel.getByRole('button', { name: 'Delete pursuit' }).click();
    await panel.getByRole('button', { name: 'Delete', exact: true }).click();

    await expect(page.getByText('Failed to persist change')).toBeVisible();
    await expect(page.locator('div.cursor-pointer').filter({ hasText: AWS })).toBeVisible();
    await expect(page.getByText('Total Pursuits').locator('..')).toContainText('4');
  });
});
