import { test, expect } from './fixtures'

test('native deployed login loads authenticated data and reload clears the session', async ({ page }) => {
  const username = process.env.SMOKE_TEST_USERNAME
  const password = process.env.SMOKE_TEST_PASSWORD
  const api = process.env.API_URL
  if (!username || !password || !api) throw new Error('Deployment test credentials and API URL are required.')
  await page.goto('/login')
  await page.locator('#email').fill(username)
  await page.locator('#password').fill(password)
  const items = page.waitForResponse((response) =>
    response.url() === `${api}/v1/items` && response.request().method() === 'GET'
  )
  await page.locator('button[type="submit"]').click()
  await expect(page).toHaveURL(/\/dashboard/)
  const response = await items
  expect(response.status()).toBe(200)
  expect(Array.isArray(await response.json())).toBe(true)
  await expect(page.locator('.create-form')).toBeVisible()
  await page.reload()
  await expect(page).toHaveURL(/\/login/)
})
