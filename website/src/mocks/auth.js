// Mock auth - flips a flag, no real Cognito needed for local dev.
export const MOCK_TOKEN = 'mock-token.saasbase.local'

export function mockLogin(email) {
  return { idToken: MOCK_TOKEN, email }
}
