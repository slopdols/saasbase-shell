// App configuration (env-driven)
// VUE_APP_API_BASE overrides the API base URL.
// Mocks are ON by default in development (`npm run serve`) and OFF for builds/tests.
const isDev = process.env.NODE_ENV === 'development'

export const config = {
  appName: 'Saasbase',
  apiBase: process.env.VUE_APP_API_BASE || (isDev ? '/api' : 'https://api.saasbase.example.com'),
  cognitoIssuer: process.env.VUE_APP_COGNITO_ISSUER || '',
  cognitoClientId: process.env.VUE_APP_COGNITO_CLIENT_ID || '',
  mocksEnabled: isDev && process.env.VUE_APP_ENABLE_MOCKS !== 'false'
}
