// Complete backend mock for local development.
// Replaces the axios adapter so the SPA never needs a real backend.
// ON by default for `vue-cli-service serve`, OFF for builds and tests.
import { itemsFixtures } from './responses/items'

const LATENCY = 150 // ms

// Route table: [method, urlRegex, handler(config) -> { status, data }]
const ROUTES = [
  ['GET', /^\/v1\/items$/, () => ({ status: 200, data: itemsFixtures.list })],
  ['GET', /^\/v1\/items\/[^/]+$/, (config) => {
    const id = config.url.split('/').pop()
    const item = itemsFixtures.list.find((i) => i.id === id)
    if (!item) return { status: 404, data: { error: { code: 'not_found', message: 'Ítem no encontrado' } } }
    return { status: 200, data: item }
  }],
  ['POST', /^\/v1\/items$/, (config) => {
    const name = JSON.parse(config.data || '{}').name || 'Sin nombre'
    const item = {
      id: `mock-item-${Date.now()}`,
      name,
      status: 'active',
      owner_sub: 'mock-user',
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      version: 0
    }
    itemsFixtures.list.unshift(item)
    return { status: 201, data: item }
  }],
  ['PUT', /^\/v1\/items\/[^/]+$/, (config) => {
    const id = config.url.split('/').pop()
    const body = JSON.parse(config.data || '{}')
    const item = itemsFixtures.list.find((i) => i.id === id)
    if (!item) return { status: 404, data: { error: { code: 'not_found', message: 'Ítem no encontrado' } } }
    item.name = body.name || item.name
    item.version += 1
    return { status: 200, data: item }
  }],
  ['DELETE', /^\/v1\/items\/[^/]+$/, (config) => {
    const id = config.url.split('/').pop()
    const item = itemsFixtures.list.find((i) => i.id === id)
    if (!item) return { status: 404, data: { error: { code: 'not_found', message: 'Ítem no encontrado' } } }
    item.status = 'deleted'
    return { status: 200, data: item }
  }],
  ['GET', /^\/v1\/auth\/me$/, () => ({
    status: 200,
    data: { sub: 'mock-user', email: 'mock@saasbase.local', groups: [], is_admin: false }
  })]
]

function respond(data, status = 200) {
  return new Promise((resolve) => {
    setTimeout(() => resolve({ data, status, statusText: 'OK', headers: {}, config: {} }), LATENCY)
  })
}

export function installMock(api) {
  api.defaults.adapter = async (config) => {
    const method = (config.method || 'get').toUpperCase()
    const url = config.url || ''
    const route = ROUTES.find(([m, re]) => m === method && re.test(url))
    if (!route) {
      return respond(
        { error: { code: 'not_found', message: `Mock sin ruta: ${method} ${url}` } },
        404
      )
    }
    const result = route[2](config)
    return respond(result.data, result.status)
  }
}
