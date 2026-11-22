const { defineConfig } = require('@playwright/test')

const baseURL = process.env.WEBSITE_URL
if (!/^https:\/\/[a-z0-9.-]+$/.test(baseURL || '')) {
  throw new Error('WEBSITE_URL must be the deployed HTTPS origin.')
}

module.exports = defineConfig({
  testDir: './e2e/deployed',
  testMatch: process.env.RUN_AUTH_SMOKE_TESTS === 'true'
    ? '**/*.spec.js'
    : '**/public.spec.js',
  timeout: 60000,
  retries: 0,
  workers: 1,
  reporter: 'line',
  use: {
    baseURL,
    browserName: 'chromium',
    trace: 'off',
    screenshot: 'off',
    video: 'off'
  }
})
