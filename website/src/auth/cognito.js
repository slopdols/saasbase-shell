import { config } from '@/config'

export function cognitoOrigin() {
  if (
    !/^https:\/\/cognito-idp\.[a-z0-9-]+\.amazonaws\.com\/[a-zA-Z0-9_-]+$/.test(config.cognitoIssuer) ||
    !/^[a-zA-Z0-9]+$/.test(config.cognitoClientId)
  ) {
    throw Object.assign(new Error('Cognito is not configured for this deployment.'), {
      code: 'auth_configuration'
    })
  }
  return new URL(config.cognitoIssuer).origin
}

export async function cognitoRequest(action, parameters) {
  const response = await fetch(cognitoOrigin(), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': `AWSCognitoIdentityProviderService.${action}`
    },
    body: JSON.stringify({ ClientId: config.cognitoClientId, ...parameters })
  })
  const data = await response.json()
  if (!response.ok) {
    const code = (data.__type || 'CognitoError').split('#').pop()
    throw Object.assign(new Error(data.message || 'Cognito request failed.'), { code })
  }
  return data
}

export function cognitoSession(result, previousRefreshToken = null) {
  const tokens = result.AuthenticationResult
  if (!tokens?.IdToken || result.ChallengeName) {
    throw Object.assign(new Error('An additional authentication challenge is required.'), {
      code: 'auth_challenge'
    })
  }
  let claims
  try {
    const encoded = tokens.IdToken.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
    const bytes = Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0))
    claims = JSON.parse(new TextDecoder().decode(bytes))
  } catch {
    throw Object.assign(new Error('Invalid authentication response.'), { code: 'auth_response' })
  }
  // Tokens come directly from Cognito over HTTPS; the API independently verifies their signatures.
  if (
    claims.iss !== config.cognitoIssuer ||
    claims.aud !== config.cognitoClientId ||
    claims.token_use !== 'id' ||
    typeof claims.sub !== 'string' ||
    typeof claims.email !== 'string' ||
    !Number.isFinite(claims.exp) ||
    claims.exp * 1000 <= Date.now() ||
    (claims['cognito:groups'] &&
      (!Array.isArray(claims['cognito:groups']) ||
        claims['cognito:groups'].some((group) => typeof group !== 'string')))
  ) {
    throw Object.assign(new Error('Invalid authentication response.'), { code: 'auth_response' })
  }
  return {
    idToken: tokens.IdToken,
    refreshToken: tokens.RefreshToken || previousRefreshToken,
    expiresAt: claims.exp * 1000,
    email: claims.email,
    sub: claims.sub,
    groups: claims['cognito:groups'] || []
  }
}
