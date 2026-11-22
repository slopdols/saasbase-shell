import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { config } from '@/config'
import { cognitoRequest, cognitoSession } from '@/auth/cognito'
import { useAuthStore } from '@/stores/auth'

vi.mock('@/config', () => ({
  config: {
    mocksEnabled: false,
    cognitoIssuer: 'https://cognito-idp.us-east-2.amazonaws.com/us-east-2_test',
    cognitoClientId: 'client123'
  }
}))

function session(claims = {}, refreshToken = 'refresh1') {
  const payload = {
    iss: config.cognitoIssuer, aud: config.cognitoClientId, token_use: 'id',
    sub: 'test-user', email: 'test@example.com', exp: Math.floor(Date.now() / 1000) + 3600,
    'cognito:groups': [], ...claims
  }
  return {
    AuthenticationResult: {
      IdToken: `header.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.signature`,
      ...(refreshToken ? { RefreshToken: refreshToken } : {})
    }
  }
}

function reply(data, ok = true) {
  return { ok, json: async () => data }
}

describe('native Cognito authentication', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    config.mocksEnabled = false
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-01-01T00:00:00Z'))
    vi.stubGlobal('fetch', vi.fn())
  })
  afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals() })

  it('registers, verifies and resends codes using the public app client', async () => {
    fetch.mockResolvedValue(reply({}))
    const auth = useAuthStore()
    await auth.register('test@example.com', 'Test-only!123')
    await auth.confirmRegistration('test@example.com', '012345')
    await auth.resendConfirmation('test@example.com')
    const requests = fetch.mock.calls.map(([url, options]) => ({
      url, action: options.headers['X-Amz-Target'].split('.').pop(), body: JSON.parse(options.body)
    }))
    expect(requests).toEqual([
      { url: 'https://cognito-idp.us-east-2.amazonaws.com', action: 'SignUp', body: {
        ClientId: 'client123', Username: 'test@example.com', Password: 'Test-only!123',
        UserAttributes: [{ Name: 'email', Value: 'test@example.com' }]
      } },
      { url: 'https://cognito-idp.us-east-2.amazonaws.com', action: 'ConfirmSignUp', body: {
        ClientId: 'client123', Username: 'test@example.com', ConfirmationCode: '012345'
      } },
      { url: 'https://cognito-idp.us-east-2.amazonaws.com', action: 'ResendConfirmationCode', body: {
        ClientId: 'client123', Username: 'test@example.com'
      } }
    ])
  })

  it('signs in without persisting credentials or tokens', async () => {
    const storage = vi.spyOn(Storage.prototype, 'setItem')
    const result = session({ 'cognito:groups': ['admin'] })
    fetch.mockResolvedValue(reply(result))
    const auth = useAuthStore()
    await auth.login('test@example.com', 'Test-only!123')
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toMatchObject({
      AuthFlow: 'USER_PASSWORD_AUTH', AuthParameters: { USERNAME: 'test@example.com', PASSWORD: 'Test-only!123' }
    })
    expect(auth.isAuthenticated).toBe(true)
    expect(auth.isAdmin).toBe(true)
    expect(await auth.getIdToken()).toBe(result.AuthenticationResult.IdToken)
    expect(storage).not.toHaveBeenCalled()
    expect(JSON.stringify(auth.$state)).not.toContain('Test-only!123')
    storage.mockRestore()
  })

  it('reports confirmation errors without creating a session', async () => {
    fetch.mockResolvedValue(reply({ __type: 'UserNotConfirmedException', message: 'Verify your email.' }, false))
    const auth = useAuthStore()
    await expect(auth.login('test@example.com', 'Test-only!123')).rejects.toMatchObject({ code: 'UserNotConfirmedException' })
    expect(auth.isAuthenticated).toBe(false)
    expect(auth.loading).toBe(false)
  })

  it.each([
    { iss: 'https://wrong.example.com' }, { aud: 'wrongClient' }, { token_use: 'access' },
    { exp: 0 }, { 'cognito:groups': [123] }
  ])('rejects mismatched or expired token claims: %j', (claims) => {
    expect(() => cognitoSession(session(claims))).toThrow('Invalid authentication response')
  })

  it('reports unsupported challenges and malformed tokens', () => {
    expect(() => cognitoSession({ ChallengeName: 'SMS_MFA' })).toThrow('challenge')
    expect(() => cognitoSession({ AuthenticationResult: { IdToken: 'invalid' } })).toThrow('Invalid authentication response')
  })

  it('rejects unsafe/missing public configuration before sending credentials', async () => {
    const issuer = config.cognitoIssuer
    config.cognitoIssuer = 'https://attacker.example.com/pool'
    try {
      await expect(cognitoRequest('InitiateAuth', {})).rejects.toMatchObject({ code: 'auth_configuration' })
      expect(fetch).not.toHaveBeenCalled()
    } finally { config.cognitoIssuer = issuer }
  })

  it('shares a refresh between concurrent API requests and retains the refresh token', async () => {
    const auth = useAuthStore()
    auth.setSession(cognitoSession(session()))
    vi.setSystemTime(auth.expiresAt - 20000)
    const refreshed = session({}, null)
    fetch.mockResolvedValue(reply(refreshed))
    const tokens = await Promise.all([auth.getIdToken(), auth.getIdToken()])
    expect(tokens).toEqual([refreshed.AuthenticationResult.IdToken, refreshed.AuthenticationResult.IdToken])
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(fetch.mock.calls[0][1].body).AuthParameters).toEqual({ REFRESH_TOKEN: 'refresh1' })
    expect(auth.refreshToken).toBe('refresh1')
  })

  it('does not restore a session when logout happens during refresh', async () => {
    const auth = useAuthStore()
    auth.setSession(cognitoSession(session()))
    vi.setSystemTime(auth.expiresAt - 20000)
    let resolve
    fetch.mockReturnValue(new Promise((done) => { resolve = done }))
    const pending = auth.getIdToken()
    auth.logout()
    resolve(reply(session()))
    await expect(pending).rejects.toMatchObject({ code: 'session_expired' })
    expect(auth.isAuthenticated).toBe(false)
  })

  it('does not clear a newer login when the previous session refresh fails', async () => {
    const auth = useAuthStore()
    auth.setSession(cognitoSession(session()))
    vi.setSystemTime(auth.expiresAt - 20000)
    let resolve
    fetch.mockReturnValueOnce(new Promise((done) => { resolve = done }))
    const pending = auth.getIdToken()
    auth.logout()
    fetch.mockResolvedValueOnce(reply(session({ sub: 'new-user' }, 'refresh2')))
    await auth.login('test@example.com', 'Test-only!123')
    resolve(reply({ __type: 'NotAuthorizedException', message: 'Expired refresh token.' }, false))
    await expect(pending).rejects.toMatchObject({ code: 'NotAuthorizedException' })
    expect(auth.sub).toBe('new-user')
    expect(auth.isAuthenticated).toBe(true)
  })

  it('clears the session and propagates a failed refresh', async () => {
    const auth = useAuthStore()
    auth.setSession(cognitoSession(session()))
    vi.setSystemTime(auth.expiresAt - 20000)
    fetch.mockResolvedValue(reply({ __type: 'NotAuthorizedException', message: 'Expired refresh token.' }, false))
    await expect(auth.getIdToken()).rejects.toMatchObject({ code: 'NotAuthorizedException' })
    expect(auth.idToken).toBeNull()
    expect(auth.refreshToken).toBeNull()
  })

  it('preserves the local email-only mock flow', async () => {
    config.mocksEnabled = true
    const auth = useAuthStore()
    await auth.login('mock@example.com')
    expect(auth.isAuthenticated).toBe(true)
    expect(await auth.getIdToken()).toBe(auth.idToken)
    expect(fetch).not.toHaveBeenCalled()
  })
})
