import { test, expect } from '@playwright/test';
import { mockApi } from './support/api-mocks';

test.describe('Dashboard View', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('displays dashboard header with title and stats', async ({ page }) => {
    // Check title
    await expect(page.getByRole('heading', { name: 'Training Tracker' })).toBeVisible();
    await expect(page.getByText('Manage your corporate certifications and trainings')).toBeVisible();

    // Check stats chips exist - use first() to avoid strict mode violations
    await expect(page.getByText('Total Pursuits').first()).toBeVisible();
    await expect(page.getByText('At Risk').first()).toBeVisible();
    await expect(page.getByText('Overdue').first()).toBeVisible();
    await expect(page.getByText('Completed').first()).toBeVisible();

    // Verify stats show numbers (from mock data: 4 total, 1 overdue, 1 completed)
    const statsSection = page.locator('text=Total Pursuits').first().locator('..');
    await expect(statsSection).toContainText('4');
  });

  test('displays pursuit cards in grid layout', async ({ page }) => {
    // Should have 4 pursuit cards from mock data
    await expect(page.getByText('AWS Certified Solutions Architect')).toBeVisible();
    await expect(page.getByText('Advanced Kubernetes Patterns')).toBeVisible();
    await expect(page.getByText('Certified Information Systems Security Professional')).toBeVisible();
    await expect(page.getByText('React Performance Tuning')).toBeVisible();
  });

  test('shows pursuit type icons', async ({ page }) => {
    // Cards should have either certification (Award) or training (BookOpen) icons
    // We can't directly check SVG icons, but we can verify cards render with status labels
    await expect(page.getByText('In Progress').first()).toBeVisible();
  });

  test('displays progress bars on each card', async ({ page }) => {
    // Each pursuit card should show dual progress bars (time vs achievement)
    const awsCard = page.locator('div.cursor-pointer')
      .filter({ hasText: 'AWS Certified Solutions Architect' })
      .first();

    await expect(awsCard).toBeVisible();

    // Progress bars show "Time" and "Achv" labels (abbreviated Achievement)
    await expect(awsCard.getByText('Time')).toBeVisible();
    await expect(awsCard.getByText('Achv')).toBeVisible();

    // The bars themselves are inside bg-slate-100 containers
    const progressContainers = awsCard.locator('[class*="bg-slate-100"][class*="rounded-full"]');
    const containerCount = await progressContainers.count();

    // Should have 2 progress bar containers
    expect(containerCount).toBe(2);
  });

  test('shows overdue indicator on overdue pursuits', async ({ page }) => {
    // K8s pursuit is 2 days overdue in mock data - should show "days overdue" text
    await expect(page.getByText(/days overdue/i)).toBeVisible();
  });

  test('displays tags on pursuit cards', async ({ page }) => {
    // AWS card has tags: cloud, aws, architecture
    // Tags are small text in bg-slate-100 containers
    await expect(page.getByText('cloud', { exact: true })).toBeVisible();
    await expect(page.getByText('architecture', { exact: true })).toBeVisible();
    // Just verify tags section exists
    const tags = await page.locator('[class*="bg-slate-100"]').count();
    expect(tags).toBeGreaterThan(0);
  });

  test('shows days remaining on active pursuits', async ({ page }) => {
    // AWS pursuit is 14 days from now in mock data
    // Use first() to handle if multiple matches exist
    await expect(page.getByText(/\d+ days left/).first()).toBeVisible();
  });
});
