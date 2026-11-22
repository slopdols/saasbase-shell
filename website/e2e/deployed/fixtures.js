import { test as base, expect } from '@playwright/test'

export const test = base.extend({
  page: async ({ page, baseURL }, use) => {
    const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET
    if (bypass) {
      await page.route(`${baseURL}/**`, async (route) => {
        await route.continue({
          headers: {
            ...route.request().headers(),
            'x-vercel-protection-bypass': bypass
          }
        })
      })
    }
    await use(page)
  }
})

export { expect }
