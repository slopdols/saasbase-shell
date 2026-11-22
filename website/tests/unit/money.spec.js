import { describe, it, expect } from 'vitest'
import { formatMoney } from '@/utils/money'

describe('formatMoney', () => {
  it('formats integer minor units', () => {
    expect(formatMoney(1234, 'USD')).toContain('12')
    expect(formatMoney(5, 'USD')).toContain('0,05')
  })

  it('rejects floats', () => {
    expect(() => formatMoney(12.5, 'USD')).toThrow(TypeError)
  })

  it('rejects non-numbers', () => {
    expect(() => formatMoney('100', 'USD')).toThrow(TypeError)
  })
})
