const { defineConfig } = require('@playwright/test')
const port = process.env.PLAYWRIGHT_PORT || '8080'
const baseURL = `http://localhost:${port}`

module.exports = defineConfig({
  testDir: './e2e',
  testIgnore: ['**/auth.spec.js', '**/deployed/**'],
  timeout: 30000,
  // Bounded CI-only retries: one retry per failed test under CI (GitHub Actions
  // and the full local runner). Standalone focused runs keep 0 so flakes stay
  // reproducible; skips remain forbidden.
  retries: process.env.CI ? 1 : 0,
  use: {
    baseURL,
    trace: 'on-first-retry'
  },
  projects: [
    {
      name: 'chromium',
      use: { browserName: 'chromium' }
    }
  ],
  webServer: {
    timeout: 180000,
    command: `npm run serve -- --port ${port}`,
    url: baseURL,
    reuseExistingServer: !process.env.CI
  }
})
