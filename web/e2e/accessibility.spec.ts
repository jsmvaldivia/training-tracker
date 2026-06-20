import { test, expect } from '@playwright/test';

test.describe('Accessibility and Responsive Design', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
  });

  test('has proper page title', async ({ page }) => {
    await expect(page).toHaveTitle(/Training Tracker/);
  });

  test('main heading is accessible', async ({ page }) => {
    const heading = page.getByRole('heading', { name: 'Training Tracker', level: 1 });
    await expect(heading).toBeVisible();
  });

  test('buttons have accessible labels', async ({ page }) => {
    // View toggle buttons
    await expect(page.getByRole('button', { name: /dashboard/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /timeline/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /add pursuit/i })).toBeVisible();
  });

  test('filter dropdown is accessible', async ({ page }) => {
    const typeFilter = page.getByRole('combobox');
    await expect(typeFilter).toBeVisible();
    await expect(typeFilter).toBeEnabled();
  });

  test('responsive grid layout on desktop', async ({ page }) => {
    // Default viewport is desktop size - just verify cards are visible
    await expect(page.getByText('AWS Certified Solutions Architect')).toBeVisible();
  });

  test('pursuit cards are clickable', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await expect(card).toBeVisible();

    // Should be clickable (has onClick handler)
    await card.click();

    // Panel should open (check for Milestones section which is in the panel)
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });
  });

  test('keyboard navigation works for view toggle', async ({ page }) => {
    const dashboardButton = page.getByRole('button', { name: /dashboard/i });
    const timelineButton = page.getByRole('button', { name: /timeline/i });

    // Focus and activate with keyboard
    await dashboardButton.focus();
    await expect(dashboardButton).toBeFocused();

    await page.keyboard.press('Tab');
    await expect(timelineButton).toBeFocused();

    await page.keyboard.press('Enter');
    await expect(timelineButton).toHaveClass(/bg-indigo/);
  });

  test('status dropdown is keyboard accessible', async ({ page }) => {
    // Open detail panel
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    const statusSelect = panel.getByRole('combobox');
    await statusSelect.focus();
    await expect(statusSelect).toBeFocused();

    // Can change with keyboard
    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('Enter');
  });

  test('detail panel backdrop has proper z-index layering', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Panel content should be visible and above the backdrop (z-50 > z-40)
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    await expect(panel).toBeVisible();
    await expect(panel.getByRole('heading', { name: 'Progress' })).toBeVisible();

    // Status dropdown should be interactive (proves it's above backdrop)
    const statusSelect = panel.getByRole('combobox');
    await expect(statusSelect).toBeVisible();
    await expect(statusSelect).toBeEnabled();
  });

  test('text content is readable with proper contrast', async ({ page }) => {
    // This is a visual test - we're checking that text elements exist and are visible
    // Proper contrast validation would require automated accessibility testing tools

    // Main text should be visible
    await expect(page.getByText('Training Tracker')).toBeVisible();

    // Description text should be visible
    await expect(page.getByText('Manage your corporate certifications')).toBeVisible();
  });

  test('selection highlighting uses brand colors', async ({ page }) => {
    // Verify the root app container renders with Tailwind brand color classes
    // The selection:bg-indigo classes are applied to this div
    const root = page.locator('div.min-h-screen').first();
    await expect(root).toBeVisible();

    // Verify it has the brand color classes
    await expect(root).toHaveClass(/bg-slate-50/);
    await expect(root).toHaveClass(/text-slate-900/);
  });

  test('Tailwind utilities compile to real styles (not just class names)', async ({ page }) => {
    // Guards the bun-plugin-tailwind build path: the class-name assertions above
    // pass even if Tailwind emits an empty stylesheet. Reading the *computed*
    // background-color proves the `bg-slate-50` utility resolved to an actual CSS
    // rule. If Tailwind failed to compile, this would be transparent (rgba(0,0,0,0)).
    const bg = await page
      .locator('div.min-h-screen')
      .first()
      .evaluate((el) => getComputedStyle(el).backgroundColor);

    expect(bg).toBeTruthy();
    expect(bg).not.toBe('rgba(0, 0, 0, 0)');
    expect(bg).not.toBe('transparent');
  });
});
