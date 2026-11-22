import { test, expect } from '@playwright/test'
import { stubAnalytics } from './helpers'

test.beforeEach(async ({ page }) => {
  await stubAnalytics(page)
})

test('home page renders', async ({ page }) => {
  await page.goto('/')
  await expect(page.locator('h1')).toContainText('Bienvenido a Saasbase')
})

test('protected route redirects to login', async ({ page }) => {
  await page.goto('/dashboard')
  await expect(page).toHaveURL(/\/login/)
  await expect(page.locator('h1')).toContainText('Iniciar sesión')
})

test('mock login reaches dashboard', async ({ page }) => {
  await page.goto('/login')
  await page.locator('#email').fill('e2e@test.com')
  await page.locator('button[type="submit"]').click()
  await expect(page).toHaveURL(/\/dashboard/)
  await expect(page.locator('h1')).toContainText('Panel')
})
