import { config as loadEnv } from 'dotenv';
import { defineConfig, devices } from '@playwright/test';

loadEnv();

const baseURL = process.env.BFF_URL || 'http://localhost:8088';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 90_000,
  expect: {
    timeout: 15_000,
  },
  reporter: [['list']],
  use: {
    baseURL,
    trace: 'on-first-retry',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: {
    command:
      'ZEEBE_REST_ADDRESS=http://localhost:8080 ZEEBE_AUTHORIZATION_SERVER_URL=http://localhost:18080/auth/realms/camunda-platform/protocol/openid-connect/token BFF_ADDR=:8088 go run ../../services/cmd/webapp',
    port: 8088,
    reuseExistingServer: true,
    timeout: 180_000,
    env: {
      ...process.env,
      ZEEBE_CLIENT_ID: process.env.ZEEBE_CLIENT_ID || '',
      ZEEBE_CLIENT_SECRET: process.env.ZEEBE_CLIENT_SECRET || '',
    },
  },
});