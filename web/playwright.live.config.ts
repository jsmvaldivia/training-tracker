import { defineConfig, devices } from '@playwright/test';

// Tier 5: the live suite (issue #8). scripts/e2e-live.sh starts the real API
// on a scratch store and the real Bun proxy, then runs this config — so there
// is no webServer block here and no route mocks in e2e-live/. Run it with
// `bun test:e2e:live` (or the script directly), never with `bun test:e2e`.

const webPort = process.env.WEB_PORT ?? '3100';

export default defineConfig({
  testDir: './e2e-live',
  // The API is single-threaded and every spec mutates one shared store;
  // specs seed unique records, but serial workers keep the run deterministic.
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: [['line'], ['html', { open: 'never', outputFolder: 'playwright-report-live' }]],
  use: {
    baseURL: `http://localhost:${webPort}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium-live',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
