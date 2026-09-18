import { request } from '@playwright/test';

export const DEFAULT_BFF_URL = 'http://localhost:8088';

export function bffUrl(): string {
  return process.env.BFF_URL || DEFAULT_BFF_URL;
}

export interface HealthStatus {
  status?: string;
}

export async function checkBffHealth(baseURL: string = bffUrl()): Promise<void> {
  const context = await request.newContext({ baseURL });
  try {
    const response = await context.get('/healthz');
    let body: HealthStatus = {};
    try {
      body = (await response.json()) as HealthStatus;
    } catch {
      body = {};
    }
    if (response.status() !== 200 || body.status !== 'ok') {
      throw new Error(
        `BFF readiness check failed at ${baseURL}/healthz (HTTP ${response.status()}, body ${JSON.stringify(body)}). ` +
          'Start the BFF (./deploy/deploy.sh --webapp or the local `go run` webServer) and make sure the Camunda port-forwards are up.',
      );
    }
  } finally {
    await context.dispose();
  }
}

export async function ensureResources(): Promise<void> {
  const baseURL = bffUrl();
  await checkBffHealth(baseURL);

  const context = await request.newContext({ baseURL });
  try {
    const response = await context.post('/api/process-definitions', {
      data: { filter: {}, sort: [{ field: 'version', order: 'desc' }], page: { limit: 1 } },
    });
    if (response.status() !== 200) {
      throw new Error(
        `Cluster connectivity check via the BFF failed: POST ${baseURL}/api/process-definitions ` +
          `-> HTTP ${response.status()}: ${await response.text()}`,
      );
    }
  } finally {
    await context.dispose();
  }
}