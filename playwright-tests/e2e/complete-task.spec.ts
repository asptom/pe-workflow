import { expect, test } from '@playwright/test';

import { ensureResources } from '../utils/zeebe';
import { start855AInstance } from './helpers/instance';

test.describe.configure({ mode: 'serial' });

test.beforeAll(async () => {
  await ensureResources();
});

test('completes the review and site-visit forms for a new 855A instance', async ({ page }) => {
  const instanceId = await start855AInstance(page);

  await page.goto('/tasks');

  const reviewRow = page
    .locator('[data-test="task-row"]', { hasText: instanceId })
    .filter({ hasText: /Review Facility Application/ });
  await expect(reviewRow).toBeVisible();
  await reviewRow.click();

  await page.check('input[name="approvalDecision"][value="Approve"]');
  await page.click('[data-test="submit-form"]');

  await expect(reviewRow).toHaveCount(0);

  const siteVisitRow = page
    .locator('[data-test="task-row"]', { hasText: instanceId })
    .filter({ hasText: /Complete Site Visit Report/ });
  await expect(siteVisitRow).toBeVisible({ timeout: 60_000 });
  await siteVisitRow.click();

  await page.check('input[name="siteVerified"]');
  await page.fill('input[name="siteAddress"]', '10 Main St, Springfield');

  const fireSafety = page.locator('input[name="fireSafetyCompliant"]');
  if (await fireSafety.isVisible()) {
    await fireSafety.check();
  }

  await page.click('[data-test="submit-form"]');

  await expect(page.locator('[data-test="form-error"]')).toHaveCount(0);
  await expect(siteVisitRow).toHaveCount(0);
});