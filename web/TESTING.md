# Testing Guide

## Test Philosophy

**Tests should validate user workflows, not implementation details.**

✅ **Good**: Test that a user can click a pursuit card and see the detail panel  
❌ **Bad**: Test that a CSS class exists on a div

✅ **Good**: Test that changing status updates the UI correctly  
❌ **Bad**: Test that a specific function was called

## E2E Test Structure

### Current Coverage (40/46 passing)

**Core User Flows:**
1. **Dashboard View** - View all pursuits in card grid
2. **Filters** - Filter by type (all/certification/training)
3. **View Toggle** - Switch between dashboard and timeline
4. **Detail Panel** - Click card → open panel → view/edit details
5. **Milestone Management** - Toggle milestone states
6. **Accessibility** - Keyboard navigation, ARIA labels

### Writing Flow-Based Tests

**Pattern: Given → When → Then**

```typescript
test('user can mark a milestone as achieved', async ({ page }) => {
  // GIVEN: User opens a pursuit with pending milestones
  await page.goto('/');
  const card = page.locator('div.cursor-pointer')
    .filter({ hasText: 'AWS Certified Solutions Architect' })
    .first();
  await card.click();
  await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });

  // WHEN: User clicks a pending milestone
  const milestone = page.getByText('Pass Practice Exam 1');
  await milestone.click();

  // THEN: Milestone shows as achieved (strikethrough styling)
  // This tests the actual user-visible outcome
  await expect(milestone.locator('..'))
    .toHaveClass(/line-through/);
});
```

## Test Anti-Patterns to Avoid

### ❌ Testing Just to Pass
```typescript
// BAD: Weakened assertion that doesn't validate the feature
test('shows progress', async ({ page }) => {
  await expect(page.locator('div')).toBeVisible(); // Too generic!
});
```

### ✅ Test the Actual Feature
```typescript
// GOOD: Validates the complete user-visible outcome
test('shows time and achievement progress for active pursuits', async ({ page }) => {
  await page.goto('/');
  
  // Find a pursuit card for an in-progress pursuit
  const awsCard = page.locator('div.cursor-pointer')
    .filter({ hasText: 'AWS Certified Solutions Architect' });
  
  // Should show both progress bars with labels
  await expect(awsCard.getByText('Time')).toBeVisible();
  await expect(awsCard.getByText('Achievement')).toBeVisible();
  
  // Should show progress percentages (bars themselves)
  const progressBars = awsCard.locator('[class*="bg-indigo"]');
  expect(await progressBars.count()).toBeGreaterThan(0);
});
```

## Debugging Failing Tests

### Use Interactive UI Mode
```bash
bun test:e2e:ui
```
This shows:
- Test execution timeline
- DOM snapshots at each step
- Network requests
- Console logs
- Screenshots on failure

### Common Issues

**Strict Mode Violations**: Element appears multiple times
```typescript
// ❌ Fails: "certification" appears in header AND panel
await expect(page.getByText('certification')).toBeVisible();

// ✅ Works: Scope to specific container
const panel = page.locator('[class*="fixed"][class*="right-0"]').first();
await expect(panel.getByText('certification')).toBeVisible();
```

**Timing Issues**: Element not ready yet
```typescript
// ❌ Might fail: Panel hasn't opened yet
await card.click();
await expect(panel).toBeVisible();

// ✅ Works: Wait for panel content
await card.click();
await expect(page.getByText('Milestones')).toBeVisible({ timeout: 3000 });
```

**Wrong Selectors**: Text exists elsewhere
```typescript
// ❌ "aws" matches heading AND tag
await expect(page.getByText('aws')).toBeVisible();

// ✅ Use exact match or scope
await expect(page.getByText('aws', { exact: true })).toBeVisible();
```

## MCP Playwright for Visual Validation

**When to use MCP vs `@playwright/test`:**

### Use `@playwright/test` for:
- Automated regression tests
- CI/CD integration
- Test-driven development
- Reproducible test runs

### Use MCP Playwright for:
- Visual inspection (screenshots)
- Ad-hoc UI exploration
- Quick validation during development
- Interactive debugging
- Comparing UI states

**Example MCP workflow:**
```
// After making UI changes:
1. Start dev server: bun dev
2. Use MCP: playwright_navigate http://localhost:3000
3. Use MCP: playwright_screenshot (baseline)
4. Make changes
5. Use MCP: playwright_screenshot (comparison)
6. Verify visual differences
```

## Test Maintenance

**When tests fail:**

1. **First**: Check if the UI actually works manually
2. **If UI works**: Fix the test selectors
3. **If UI broken**: Fix the code, keep test as-is
4. **Never**: Weaken assertions just to pass

**Selector priority:**
1. User-facing text: `page.getByText('Submit')`
2. ARIA roles: `page.getByRole('button', { name: 'Submit' })`
3. Test IDs: `page.locator('[data-testid="submit-btn"]')`
4. CSS classes: Last resort, likely to break

## Current Test Status

**40/46 passing (87%)**

**6 failing tests** need investigation:
- Are they exposing real bugs?
- Do selectors need refinement?
- Are timing/waiting strategies adequate?

**Fix philosophy**: Make tests robust by improving waiting strategies and selectors, NOT by removing assertions or weakening checks.
