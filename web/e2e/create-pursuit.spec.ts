import { test, expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { mockApi } from './support/api-mocks';

// Issue #20: create a pursuit from the Add Pursuit button. The form maps its
// fields onto the PursuitCreate body from api/openapi.yaml; the new pursuit
// joins the list without a reload.

async function openForm(page: Page) {
  await page.getByRole('button', { name: /add pursuit/i }).click();
  const dialog = page.getByRole('dialog', { name: 'New pursuit' });
  await expect(dialog).toBeVisible();
  return dialog;
}

test.describe('Create pursuit', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('creates a pursuit and shows it on the dashboard', async ({ page }) => {
    const dialog = await openForm(page);

    await dialog.getByLabel('Name', { exact: true }).fill('Terraform Associate');
    await dialog.getByLabel('Type', { exact: true }).selectOption('certification');
    await dialog.getByLabel('Started', { exact: true }).fill('2026-06-01');
    await dialog.getByLabel('Target date', { exact: true }).fill('2026-12-31');
    await dialog.getByLabel('Expires', { exact: true }).fill('2028-12-31');
    await dialog.getByLabel('Tags', { exact: true }).fill('iac, hashicorp');
    await dialog.getByLabel('Notes', { exact: true }).fill('Renew every two years.');

    const request = page.waitForRequest((r) => r.method() === 'POST' && r.url().endsWith('/api/pursuits'));
    await dialog.getByRole('button', { name: 'Create pursuit' }).click();

    // The body follows the PursuitCreate schema: UTC timestamps, tags as an array.
    const body = (await request).postDataJSON();
    expect(body).toEqual({
      name: 'Terraform Associate',
      type: 'certification',
      started_at: '2026-06-01T00:00:00Z',
      target_date: '2026-12-31T00:00:00Z',
      expires_at: '2028-12-31T00:00:00Z',
      tags: ['iac', 'hashicorp'],
      description: 'Renew every two years.',
    });

    await expect(dialog).toBeHidden();
    await expect(page.getByText('Terraform Associate')).toBeVisible();
    const total = page.getByText('Total Pursuits').locator('..');
    await expect(total).toContainText('5');
  });

  test('omits optional fields left blank', async ({ page }) => {
    const dialog = await openForm(page);
    await dialog.getByLabel('Name', { exact: true }).fill('Rust Book');
    await dialog.getByLabel('Started', { exact: true }).fill('2026-07-01');
    await dialog.getByLabel('Target date', { exact: true }).fill('2026-09-30');

    const request = page.waitForRequest((r) => r.method() === 'POST' && r.url().endsWith('/api/pursuits'));
    await dialog.getByRole('button', { name: 'Create pursuit' }).click();
    const body = (await request).postDataJSON();

    expect(body).toEqual({
      name: 'Rust Book',
      type: 'training',
      started_at: '2026-07-01T00:00:00Z',
      target_date: '2026-09-30T00:00:00Z',
      tags: [],
    });
    await expect(page.getByText('Rust Book')).toBeVisible();
  });

  test('does not submit without the required fields', async ({ page }) => {
    const dialog = await openForm(page);
    let posted = false;
    page.on('request', (r) => {
      if (r.method() === 'POST') posted = true;
    });

    await dialog.getByRole('button', { name: 'Create pursuit' }).click();

    await expect(dialog).toBeVisible();
    expect(posted).toBe(false);
  });

  test('cancel closes the form without creating anything', async ({ page }) => {
    const dialog = await openForm(page);
    await dialog.getByLabel('Name', { exact: true }).fill('Abandoned');
    await dialog.getByRole('button', { name: 'Cancel' }).click();

    await expect(dialog).toBeHidden();
    await expect(page.getByText('Abandoned')).toHaveCount(0);
    await expect(page.getByText('Total Pursuits').locator('..')).toContainText('4');
  });
});

test.describe('Create pursuit — failure', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page, { failMutations: true });
    await page.goto('/');
  });

  test('a failed create keeps the form open and shows a toast', async ({ page }) => {
    const dialog = await openForm(page);
    await dialog.getByLabel('Name', { exact: true }).fill('Doomed');
    await dialog.getByLabel('Started', { exact: true }).fill('2026-07-01');
    await dialog.getByLabel('Target date', { exact: true }).fill('2026-09-30');
    await dialog.getByRole('button', { name: 'Create pursuit' }).click();

    await expect(page.getByText('Failed to persist change')).toBeVisible();
    await expect(dialog).toBeVisible();
    await expect(page.getByText('Total Pursuits').locator('..')).toContainText('4');
  });
});
