import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { mockApi } from './support/api-mocks';

// Issue #23: edit a pursuit's fields other than status from the detail panel.
// The form is prefilled, only changed fields go into the PATCH body, and the
// optimistic update rolls back with a toast on failure.

const AWS = 'AWS Certified Solutions Architect';

async function openEditForm(page: Page) {
  await page.locator('div.cursor-pointer').filter({ hasText: AWS }).first().click();
  const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
  await expect(panel.getByRole('heading', { name: AWS })).toBeVisible({ timeout: 3000 });
  await panel.getByRole('button', { name: 'Edit', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Edit pursuit' });
  await expect(dialog).toBeVisible();
  return { panel, dialog };
}

test.describe('Edit pursuit', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('prefills the form and sends only the changed fields', async ({ page }) => {
    const { panel, dialog } = await openEditForm(page);

    await expect(dialog.getByLabel('Name', { exact: true })).toHaveValue(AWS);
    await expect(dialog.getByLabel('Type', { exact: true })).toHaveValue('certification');
    await expect(dialog.getByLabel('Tags', { exact: true })).toHaveValue('cloud, aws, architecture');
    await expect(dialog.getByLabel('Started', { exact: true })).toHaveValue(/^\d{4}-\d{2}-\d{2}$/);

    await dialog.getByLabel('Name', { exact: true }).fill('AWS SAA');
    await dialog.getByLabel('Tags', { exact: true }).fill('cloud, aws');
    const request = page.waitForRequest((r) => r.method() === 'PATCH' && r.url().endsWith('/api/pursuits/p1'));
    await dialog.getByRole('button', { name: 'Save changes' }).click();

    expect((await request).postDataJSON()).toEqual({ name: 'AWS SAA', tags: ['cloud', 'aws'] });
    await expect(dialog).toBeHidden();
    await expect(panel.getByRole('heading', { name: 'AWS SAA' })).toBeVisible();
    await expect(panel.getByText('architecture', { exact: true })).toHaveCount(0);
    await expect(page.locator('div.cursor-pointer').filter({ hasText: 'AWS SAA' })).toBeVisible();
  });

  test('saving without changes sends nothing and closes', async ({ page }) => {
    const { dialog } = await openEditForm(page);
    let patched = false;
    page.on('request', (r) => {
      if (r.method() === 'PATCH') patched = true;
    });

    await dialog.getByRole('button', { name: 'Save changes' }).click();

    await expect(dialog).toBeHidden();
    expect(patched).toBe(false);
  });
});

test.describe('Edit pursuit — failure', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page, { failMutations: true });
    await page.goto('/');
  });

  test('a failed edit rolls back the panel and keeps the form open', async ({ page }) => {
    const { panel, dialog } = await openEditForm(page);
    await dialog.getByLabel('Name', { exact: true }).fill('AWS SAA');
    await dialog.getByRole('button', { name: 'Save changes' }).click();

    await expect(page.getByText('Failed to persist change')).toBeVisible();
    await expect(dialog).toBeVisible();
    await expect(panel.getByRole('heading', { name: AWS })).toBeVisible();
  });
});
