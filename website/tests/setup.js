// Global test setup for Vitest.
// Keeps the DOM clean between tests and disables noisy warnings.
import { afterEach, vi } from 'vitest'

afterEach(() => {
  document.body.innerHTML = ''
  vi.restoreAllMocks()
})
