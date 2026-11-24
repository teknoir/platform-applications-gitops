import { defineConfig, devices } from '@playwright/test';

// The verify spec reads BASE_URL, TEST_USER, TEST_PASSWORD and REVISION from the environment at run time
// (tests/staging.spec.ts), so `npx playwright test --list` needs none of them and no browser.
// ignoreHTTPSErrors stays false on purpose: a certificate error is itself a finding.
export default defineConfig({
  testDir: './tests',
  // Written outside the checkout so the non-root pwuser of the verify image can always create it.
  outputDir: process.env.PLAYWRIGHT_OUTPUT_DIR || '/tmp/gitops-verify-results',
  timeout: 180_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  forbidOnly: !!process.env.CI,
  reporter: [['list']],
  use: {
    baseURL: process.env.BASE_URL,
    headless: true,
    ignoreHTTPSErrors: false,
    // Nothing may capture the login form: a screenshot, a video or a trace taken while #password is filled
    // stores the password. The spec takes its own screenshot after sign-in.
    screenshot: 'off',
    trace: 'off',
    video: 'off',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
