import { describe, it, expect, beforeEach } from 'vitest'
import api, { setTokenProvider } from '@/api/client'

function response(status, data) {
  return { data, status, statusText: 'OK', headers: {}, config: {} }
}

describe('api client', () => {
  beforeEach(() => {
    setTokenProvider(() => null)
  })

  it('injects bearer token from the provider', async () => {
    let captured
    api.defaults.adapter = async (config) => {
      captured = config
      return response(200, {})
    }
    setTokenProvider(async () => 'tok-123')
    await api.get('/v1/items')
    expect(captured.headers.Authorization).toBe('Bearer tok-123')
  })

  it('omits the header when there is no token', async () => {
    let captured
    api.defaults.adapter = async (config) => {
      captured = config
      return response(200, {})
    }
    await api.get('/v1/items')
    expect(captured.headers.Authorization).toBeUndefined()
  })

  it('normalizes network errors', async () => {
    api.defaults.adapter = () => Promise.reject(new Error('network down'))
    await expect(api.get('/v1/items')).rejects.toMatchObject({ code: 'network_error' })
  })

  it('preserves refresh failures and does not send an unauthenticated request', async () => {
    let called = false
    api.defaults.adapter = async () => { called = true; return response(200, {}) }
    const error = Object.assign(new Error('Please sign in again.'), { code: 'session_expired' })
    setTokenProvider(async () => { throw error })
    await expect(api.get('/v1/items')).rejects.toBe(error)
    expect(called).toBe(false)
  })

  it('normalizes backend error envelopes', async () => {
    api.defaults.adapter = () =>
      Promise.reject({
        response: { data: { error: { code: 'conflict', message: 'Conflicto de versión', details: {} } } }
      })
    await expect(api.get('/v1/items')).rejects.toMatchObject({
      code: 'conflict',
      message: 'Conflicto de versión'
    })
  })
})
