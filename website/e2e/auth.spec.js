import { test, expect } from '@playwright/test'
import { fakeJwt, stubAnalytics } from './helpers'

const issuer = 'https://cognito-idp.us-east-2.amazonaws.com/us-east-2_test'
const password = 'Browser-test!123'

test.beforeEach(async ({ page }) => {
  await stubAnalytics(page)
  await page.route('https://shell-api.example.com/**', async (route) => {
    await route.fulfill({ json: route.request().url().endsWith('/v1/items') ? [] : {} })
  })
})

test('registration, code resend, verification and native login reach the dashboard', async ({ page }) => {
  const actions = []
  await page.route('https://cognito-idp.us-east-2.amazonaws.com/**', async (route) => {
    const request = route.request()
    const action = request.headers()['x-amz-target'].split('.').pop()
    actions.push(action)
    const body = request.postDataJSON()
    expect(body.ClientId).toBe('client123')
    if (action === 'SignUp' || action === 'InitiateAuth') { expect(body.Password || body.AuthParameters.PASSWORD).toBe(password) }
    if (action === 'ConfirmSignUp') { expect(body.ConfirmationCode).toBe('012345') }
    const result = action === 'InitiateAuth' ? {
      AuthenticationResult: {
        IdToken: fakeJwt({ iss: issuer, aud: 'client123', token_use: 'id', exp: Math.floor(Date.now() / 1000) + 3600 }),
        RefreshToken: 'fake-refresh'
      }
    } : { UserConfirmed: false }
    await route.fulfill({ json: result })
  })
  await page.goto('/login')
  await page.getByRole('button', { name: 'Crear cuenta', exact: true }).click()
  await page.locator('#email').fill('e2e@test.com')
  await page.locator('#password').fill(password)
  await page.locator('button[type="submit"]').click()
  await expect(page.locator('#code')).toBeVisible()
  await page.getByRole('button', { name: 'Reenviar código' }).click()
  await page.locator('#code').fill('012345')
  await page.locator('button[type="submit"]').click()
  await expect(page.locator('#password')).toHaveValue('')
  await page.locator('#password').fill(password)
  await page.locator('button[type="submit"]').click()
  await expect(page).toHaveURL(/\/dashboard/)
  expect(actions).toEqual(['SignUp', 'ResendConfirmationCode', 'ConfirmSignUp', 'InitiateAuth'])
})

test('unconfirmed login switches to verification and errors stay visible', async ({ page }) => {
  await page.route('https://cognito-idp.us-east-2.amazonaws.com/**', async (route) => {
    const action = route.request().headers()['x-amz-target'].split('.').pop()
    await route.fulfill({ status: 400, json: {
      __type: action === 'InitiateAuth' ? 'UserNotConfirmedException' : 'CodeMismatchException',
      message: action === 'InitiateAuth' ? 'Verify your email.' : 'Invalid verification code.'
    } })
  })
  await page.goto('/login')
  await page.locator('#email').fill('e2e@test.com')
  await page.locator('#password').fill(password)
  await page.locator('button[type="submit"]').click()
  await expect(page.locator('#code')).toBeVisible()
  await page.locator('#code').fill('000000')
  await page.locator('button[type="submit"]').click()
  await expect(page.getByText('Invalid verification code.')).toBeVisible()
  await expect(page).toHaveURL(/\/login/)
})
