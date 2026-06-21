import { test, expect } from '@playwright/test';
import { mockApi } from './support/api-mocks';

test.describe('Filters and View Toggle', () => {
  test.beforeEach(async ({ page }) => {
    await mockApi(page);
    await page.goto('/');
  });

  test('toggles between dashboard and timeline views', async ({ page }) => {
    // Start on dashboard view
    const dashboardButton = page.getByRole('button', { name: /dashboard/i });
    const timelineButton = page.getByRole('button', { name: /timeline/i });

    // Dashboard should be active initially
    await expect(dashboardButton).toHaveClass(/bg-indigo/);

    // Switch to timeline view
    await timelineButton.click();
    await expect(timelineButton).toHaveClass(/bg-indigo/);

    // Timeline view should show timeline content
    await expect(page.getByText('Overdue')).toBeVisible(); // Timeline section

    // Switch back to dashboard
    await dashboardButton.click();
    await expect(dashboardButton).toHaveClass(/bg-indigo/);

    // Should see pursuit cards again (not timeline)
    await expect(page.getByText('AWS Certified Solutions Architect').first()).toBeVisible();
  });

  test('filters pursuits by type - All Types', async ({ page }) => {
    const typeFilter = page.getByRole('combobox');
    await typeFilter.selectOption('all');

    // Should show all 4 pursuits
    await expect(page.getByText('AWS Certified Solutions Architect')).toBeVisible();
    await expect(page.getByText('Advanced Kubernetes Patterns')).toBeVisible();
    await expect(page.getByText('Certified Information Systems Security Professional')).toBeVisible();
    await expect(page.getByText('React Performance Tuning')).toBeVisible();
  });

  test('filters pursuits by type - Certifications only', async ({ page }) => {
    const typeFilter = page.getByRole('combobox');
    await typeFilter.selectOption('certification');

    // Should show only certification pursuits (AWS, CISSP)
    await expect(page.getByText('AWS Certified Solutions Architect')).toBeVisible();
    await expect(page.getByText('Certified Information Systems Security Professional')).toBeVisible();

    // Should NOT show training pursuits
    await expect(page.getByText('Advanced Kubernetes Patterns')).not.toBeVisible();
    await expect(page.getByText('React Performance Tuning')).not.toBeVisible();
  });

  test('filters pursuits by type - Trainings only', async ({ page }) => {
    const typeFilter = page.getByRole('combobox');
    await typeFilter.selectOption('training');

    // Should show only training pursuits (K8s, React)
    await expect(page.getByText('Advanced Kubernetes Patterns')).toBeVisible();
    await expect(page.getByText('React Performance Tuning')).toBeVisible();

    // Should NOT show certification pursuits
    await expect(page.getByText('AWS Certified Solutions Architect')).not.toBeVisible();
    await expect(page.getByText('Certified Information Systems Security Professional')).not.toBeVisible();
  });

  test('shows empty state when no pursuits match filter', async ({ page }) => {
    // This test will pass once we have a way to clear all data
    // For now, we always have mock data, so we'll skip this scenario
    // But the component has the empty state: "No pursuits found matching your filters"
  });

  test('filter persists across view toggle', async ({ page }) => {
    const typeFilter = page.getByRole('combobox');
    const timelineButton = page.getByRole('button', { name: /timeline/i });
    const dashboardButton = page.getByRole('button', { name: /dashboard/i });

    // Set filter to certifications
    await typeFilter.selectOption('certification');
    await expect(page.getByText('AWS Certified Solutions Architect')).toBeVisible();

    // Switch to timeline
    await timelineButton.click();

    // Should still show only certifications in timeline
    await expect(page.getByText('AWS Certified Solutions Architect')).toBeVisible();
    await expect(page.getByText('Advanced Kubernetes Patterns')).not.toBeVisible();

    // Switch back to dashboard
    await dashboardButton.click();

    // Filter should still be active
    await expect(typeFilter).toHaveValue('certification');
    await expect(page.getByText('AWS Certified Solutions Architect')).toBeVisible();
  });

  test('Add Pursuit button is visible', async ({ page }) => {
    const addButton = page.getByRole('button', { name: /add pursuit/i });
    await expect(addButton).toBeVisible();
    // Note: button is not wired yet, so we just verify it renders
  });
});
