import { expect, test } from '@playwright/test';

import { ensureResources } from '../utils/zeebe';
import { start855AInstance } from './helpers/instance';

test.describe.configure({ mode: 'serial' });

test.beforeAll(async () => {
  await ensureResources();
});

test('renders the bpmn-js diagram and the sequence timeline', async ({ page }) => {
  const instanceId = await start855AInstance(page);

  await page.goto(`/process/${instanceId}`);

  const canvas = page.locator('.djs-container');
  await expect(canvas).toBeVisible();
  await expect(canvas.locator('svg')).toBeVisible();
  await expect(canvas.locator('svg .bpmn-shape').first()).toBeVisible();
  await expect(canvas.locator('svg .bpmn-label').first()).toBeVisible();

  await expect(page.locator('.timeline li').first()).toBeVisible();
  expect(await page.locator('.timeline li').count()).toBeGreaterThan(0);
});