// Shared helpers for Playwright E2E tests.

// Builds a fake (unsigned) JWT-shaped token for simulated auth flows.
// Real auth uses Cognito; E2E tests never hit a real identity provider.
export function fakeJwt(payload = {}) {
  const header = { alg: 'none', typ: 'JWT' }
  const body = {
    sub: 'e2e-user',
    email: 'e2e@test.com',
    'cognito:groups': [],
    iat: Math.floor(Date.now() / 1000),
    ...payload
  }
  const enc = (obj) => btoa(JSON.stringify(obj)).replace(/=/g, '')
  return `${enc(header)}.${enc(body)}.fake-signature`
}

// Prevents first-party analytics from sending during E2E runs.
export async function stubAnalytics(page) {
  await page.addInitScript(() => {
    window.__saasbaseAnalyticsStub = true
  })
}

// Placeholder: bypass cookie consent banner if one is added later.
export async function dismissConsent(page) {
  // no consent UI in the shell yet
}

// Placeholder: shim Stripe.js if payments are added later.
export async function stubStripe(page) {
  await page.addInitScript(() => {
    window.Stripe = () => ({ elements: () => ({ create: () => ({}) }) })
  })
}
