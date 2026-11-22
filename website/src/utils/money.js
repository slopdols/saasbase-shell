// Money safety: internal math is in integer minor units.
// Division by 100 happens ONLY here, for display.
export function formatMoney(minor, currency = 'USD') {
  if (!Number.isInteger(minor)) {
    throw new TypeError('money must be an integer in minor units')
  }
  return new Intl.NumberFormat('es-ES', {
    style: 'currency',
    currency,
    currencyDisplay: 'narrowSymbol'
  }).format(minor / 100)
}
