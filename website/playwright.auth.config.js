const { defineConfig } = require('@playwright/test')
const base = require('./playwright.config')
const port = process.env.PLAYWRIGHT_PORT || '8081'
const baseURL = `http://localhost:${port}`

module.exports = defineConfig({
  ...base,
  testMatch: '**/auth.spec.js',
  testIgnore: [],
  use: { ...base.use, baseURL },
  webServer: {
    timeout: 180000,
    command: `npm run serve -- --port ${port}`,
    url: baseURL,
    reuseExistingServer: false,
    env: {
      VUE_APP_ENABLE_MOCKS: 'false',
      VUE_APP_API_BASE: 'https://shell-api.example.com',
      VUE_APP_COGNITO_ISSUER: 'https://cognito-idp.us-east-2.amazonaws.com/us-east-2_test',
      VUE_APP_COGNITO_CLIENT_ID: 'client123'
    }
  }
})
