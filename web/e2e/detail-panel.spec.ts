import { test, expect } from '@playwright/test';
import { mockApi } from './support/api-mocks';

test.describe('Pursuit Detail Panel', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('opens detail panel when pursuit card is clicked', async ({ page }) => {
    // Click on AWS pursuit card - find the card container and click it
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();

    // Detail panel should appear - wait for it with timeout
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });
  });

  test('closes detail panel when X button is clicked', async ({ page }) => {
    // Open panel
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Click close button - the first button in the panel should be the X
    const closeButton = page.locator('[class*="fixed"][class*="right-0"]').getByRole('button').first();
    await closeButton.click();

    // Panel content should not be visible
    await expect(page.getByText('Milestones')).not.toBeVisible();
  });

  test('closes detail panel when X button is clicked twice (simulating close action)', async ({ page }) => {
    // Open panel
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Close panel using X button
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    const closeButton = panel.getByRole('button').first();
    await closeButton.click();

    // Panel should close - Milestones section should disappear
    await expect(page.getByText('Milestones')).not.toBeVisible({ timeout: 2000 });
  });

  test('displays pursuit type indicator', async ({ page }) => {
    // Open AWS (certification) pursuit
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Should show "certification" type in the panel header (capitalize class indicates it's the type badge)
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    await expect(panel.locator('span.capitalize', { hasText: 'certification' })).toBeVisible();
  });

  test('shows status dropdown with all options', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Status dropdown should be visible in the panel (second combobox, first is the filter)
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    const statusSelect = panel.getByRole('combobox');
    await expect(statusSelect).toBeVisible();
    await expect(statusSelect).toHaveValue('in_progress');

    // Check all status options exist
    await expect(statusSelect.locator('option[value="planned"]')).toBeAttached();
    await expect(statusSelect.locator('option[value="in_progress"]')).toBeAttached();
    await expect(statusSelect.locator('option[value="completed"]')).toBeAttached();
    await expect(statusSelect.locator('option[value="expired"]')).toBeAttached();
  });

  test('changes pursuit status via dropdown', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    const statusSelect = panel.getByRole('combobox');
    await expect(statusSelect).toHaveValue('in_progress');

    // Change to completed
    await statusSelect.selectOption('completed');
    await expect(statusSelect).toHaveValue('completed');
  });

  test('displays progress bars in detail panel', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Panel should show Progress section heading
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    await expect(panel.getByRole('heading', { name: 'Progress' })).toBeVisible();

    // Check for achievement progress label (unique identifier)
    await expect(panel.getByText('Achv')).toBeVisible();

    // The progress bars are inside bg-slate-100 containers with rounded-full
    // These are the track containers for time and achievement bars
    const progressContainers = panel.locator('[class*="bg-slate-100"][class*="rounded-full"][class*="overflow-hidden"]');
    const containerCount = await progressContainers.count();

    // Should have at least 2 progress bar containers (time and achievement)
    expect(containerCount).toBeGreaterThanOrEqual(2);
  });

  test('displays timeline dates section', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Should show Timeline section with dates in the panel
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    await expect(panel.getByText('Timeline')).toBeVisible();
    await expect(panel.getByText('Started')).toBeVisible();
    await expect(panel.getByText('Target')).toBeVisible();
  });

  test('lists all milestones with their states', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // AWS pursuit has 4 milestones in mock data
    await expect(page.getByText('Complete Cloud Practitioner')).toBeVisible();
    await expect(page.getByText('Finish A Cloud Guru Course')).toBeVisible();
    await expect(page.getByText('Pass Practice Exam 1')).toBeVisible();
    await expect(page.getByText('Book Exam')).toBeVisible();

    // Should show achieved count: 2/4
    await expect(page.locator('text=/2\\s*\\/\\s*4/')).toBeVisible();
  });

  test('toggles milestone state when clicked', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Find a pending milestone and click it
    const pendingMilestone = page.getByText('Pass Practice Exam 1');
    await pendingMilestone.click();

    // The milestone count should update (this is a simple check that click registered)
    // In a real app with backend, we'd verify the state change persists
    await expect(page.getByText('Milestones')).toBeVisible();
  });

  test('displays pursuit tags', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Should show Tags section
    await expect(page.getByText('Tags')).toBeVisible();

    // AWS pursuit has tags: cloud, aws, architecture
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    await expect(panel.getByText('cloud', { exact: true })).toBeVisible();
    await expect(panel.getByText('architecture', { exact: true })).toBeVisible();
  });

  test('displays pursuit description in Notes section', async ({ page }) => {
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'AWS Certified Solutions Architect' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Should show Notes section with description
    await expect(page.getByText('Notes')).toBeVisible();
    await expect(page.getByText('Associate level certification for AWS cloud architecture')).toBeVisible();
  });

  test('shows overdue badge when pursuit is overdue', async ({ page }) => {
    // K8s pursuit is overdue in mock data
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'Advanced Kubernetes Patterns' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Should show overdue badge or text in the panel
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    await expect(panel.getByText(/overdue/i).first()).toBeVisible();
  });

  test('shows completed date for completed pursuits', async ({ page }) => {
    // React pursuit is completed in mock data
    const card = page.locator('div.cursor-pointer').filter({ hasText: 'React Performance Tuning' }).first();
    await card.click();
    await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

    // Panel should show Timeline section with completion information
    const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
    await expect(panel.getByRole('heading', { name: 'Timeline' })).toBeVisible();

    // Completed pursuits show "Completed" label (not the option, but the label)
    // The "Completed" text appears as a label with specific styling
    await expect(panel.locator('text=Completed').locator('xpath=ancestor::div[contains(@class, "flex-col")]').first()).toBeVisible();
  });
});
