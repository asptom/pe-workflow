import { expect, type Page } from '@playwright/test';

export const ENROLLMENT_ORCHESTRATOR_ID = 'Enrollment_Orchestrator';

export interface Start855AInstanceOptions {
  force?: string;
}

interface DefinitionItem {
  processDefinitionKey: string;
  processDefinitionId: string;
}

export async function start855AInstance(
  page: Page,
  options: Start855AInstanceOptions = {},
): Promise<string> {
  await page.goto('/');

  if (options.force) {
    await page.route('**/api/process-instances/start', async (route) => {
      const payload = JSON.parse(route.request().postData() ?? '{}');
      payload.variables = { ...(payload.variables ?? {}), force: options.force };
      await route.continue({ postData: JSON.stringify(payload) });
    });
  }

  const definitionsResponse = page.waitForResponse(
    (r) => r.request().method() === 'POST' && r.url().includes('/api/process-definitions'),
  );
  await page.click('[data-test="start-process"]');

  const definitions = await (await definitionsResponse).json();
  const orchestrator = (definitions.items as DefinitionItem[] | undefined)?.find(
    (d) => d.processDefinitionId === ENROLLMENT_ORCHESTRATOR_ID,
  );
  expect(
    orchestrator,
    `No enrollment definition (${
      definitions.items as DefinitionItem[] | undefined
    }) version of ${ENROLLMENT_ORCHESTRATOR_ID} found in the dashboard picker`,
  ).toBeDefined();

  await page.selectOption('#definition-select', orchestrator!.processDefinitionKey);
  await page.waitForSelector('select[name="provider.enrollmentType"]');

  await page.selectOption('select[name="provider.enrollmentType"]', '855A');
  await page.fill('input[name="provider.legalName"]', 'Acme Clinic');
  await page.fill('input[name="provider.npi"]', '1234567890');
  await page.fill('input[name="provider.tin"]', '12-3456789');
  await page.selectOption('select[name="submissionMethod"]', 'PECOS');
  await page.fill('input[name="provider.filingDate"]', '2026-08-27');

  const startResponse = page.waitForResponse(
    (r) => r.request().method() === 'POST' && r.url().includes('/api/process-instances/start'),
  );
  await page.click('[data-test="submit-form"]');

  const started = await (await startResponse).json();
  const instanceKey = started.processInstanceKey as string | undefined;
  expect(instanceKey, 'start response did not include processInstanceKey').toBeDefined();
  return instanceKey!;
}