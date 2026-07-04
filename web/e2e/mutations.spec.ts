import { test, expect } from '@playwright/test';
import { mockApi } from './support/api-mocks';

// Issue #4: the write path. Mutations are optimistic — the UI updates
// immediately, reconciles the server response, and rolls back + toasts on
// failure. These specs drive both the happy path and the 500 → rollback + toast
// path via the route-mock's `failMutations` switch.

const AWS = 'AWS Certified Solutions Architect';

async function openAws(page: import('@playwright/test').Page) {
  const card = page.locator('div.cursor-pointer').filter({ hasText: AWS }).first();
  await card.click();
  await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });
}

test.describe('Mutations — optimistic success', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('toggling a pending milestone persists and bumps the achieved count', async ({ page }) => {
    await openAws(page);

    // AWS seeds 2 of 4 milestones achieved.
    await expect(page.locator('text=/2\\s*\\/\\s*4/')).toBeVisible();

    await page.getByText('Pass Practice Exam 1').click();

    // Optimistic flip + reconciled server milestone -> 3 of 4 achieved.
    await expect(page.locator('text=/3\\s*\\/\\s*4/')).toBeVisible();
  });

  test('changing status to completed sticks after reconcile', async ({ page }) => {
    await openAws(page);

    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    const statusSelect = panel.getByRole('combobox');
    await expect(statusSelect).toHaveValue('in_progress');

    await statusSelect.selectOption('completed');
    await expect(statusSelect).toHaveValue('completed');
  });
});

test.describe('Mutations — failure rolls back and toasts', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page, { failMutations: true });
    await page.goto('/');
  });

  test('a failed milestone toggle rolls back and shows a toast', async ({ page }) => {
    await openAws(page);
    await expect(page.locator('text=/2\\s*\\/\\s*4/')).toBeVisible();

    await page.getByText('Pass Practice Exam 1').click();

    // The rollback toast is announced in the aria-live region.
    await expect(page.getByText('Failed to persist change')).toBeVisible();

    // Count returns to the pre-toggle value (rolled back).
    await expect(page.locator('text=/2\\s*\\/\\s*4/')).toBeVisible();
  });

  test('a failed status change rolls back the dropdown and shows a toast', async ({ page }) => {
    await openAws(page);

    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    const statusSelect = panel.getByRole('combobox');
    await expect(statusSelect).toHaveValue('in_progress');

    await statusSelect.selectOption('completed');

    await expect(page.getByText('Failed to persist change')).toBeVisible();
    await expect(statusSelect).toHaveValue('in_progress');
  });
});
