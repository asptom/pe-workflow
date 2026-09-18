import { expect, test } from '@playwright/test';

import { ensureResources } from '../utils/zeebe';
import { start855AInstance } from './helpers/instance';

test.describe.configure({ mode: 'serial' });

test.beforeAll(async () => {
  await ensureResources();
});

test('starts a 855A instance from the dashboard and shows its detail page', async ({ page }) => {
  const instanceId = await start855AInstance(page);

  await page.goto(`/process/${instanceId}`);

  await expect(page.getByRole('heading', { name: new RegExp(instanceId) })).toBeVisible();

  const metadata = page.locator('.meta-card').first();
  await expect(metadata).toContainText('Enrollment_Orchestrator');
  await expect(metadata.getByText('ACTIVE')).toBeVisible();

  await expect(page.locator('.diagram-card')).toContainText('Diagram');
  await expect(page.locator('.djs-container svg')).toBeVisible();
  await expect(page.locator('.djs-container .bpmn-shape').first()).toBeVisible();

  await expect(page.locator('.timeline li').first()).toBeVisible();
});