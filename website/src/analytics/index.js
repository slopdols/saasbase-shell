// First-party analytics (no third-party scripts).
// Events are always sent - even without consent - just under an anonymous ID.

const queue = []
let initialized = false
let anonymousId = null

export function initAnalytics() {
  initialized = true
  anonymousId = `anon-${Math.random().toString(36).slice(2, 10)}`
  while (queue.length) {
    const [name, payload] = queue.shift()
    trackEvent(name, payload)
  }
}

export function trackEvent(name, payload = {}) {
  const event = { name, payload, anonymousId, at: new Date().toISOString() }
  if (!initialized) {
    queue.push([name, payload])
    return
  }
  // TODO: send to first-party analytics endpoint when defined.
  if (import.meta.env?.DEV || process.env.NODE_ENV === 'development') {
    // eslint-disable-next-line no-console
    console.debug('[analytics]', event)
  }
}
