const { defineConfig } = require('@playwright/test')
const port = process.env.PLAYWRIGHT_PORT || '8080'
const baseURL = `http://localhost:${port}`

module.exports = defineConfig({
  testDir: './e2e',
  testIgnore: ['**/auth.spec.js', '**/deployed/**'],
  timeout: 30000,
  retries: 0,
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
