import { defineStore } from 'pinia'
import { setTokenProvider } from '@/api/client'
import { config } from '@/config'
import { mockLogin } from '@/mocks/auth'
import { cognitoRequest, cognitoSession } from '@/auth/cognito'

export const useAuthStore = defineStore('auth', {
  state: () => ({
    idToken: null,
    refreshToken: null,
    expiresAt: null,
    refreshing: null,
    email: null,
    sub: null,
    groups: [],
    loading: false
  }),

  getters: {
    isAuthenticated: (state) => !!state.idToken,
    isAdmin: (state) => state.groups.includes('admin')
  },

  actions: {
    async login(email, password) {
      this.loading = true
      try {
        if (config.mocksEnabled) {
          const { idToken } = mockLogin(email)
          this.setSession({ idToken, email, sub: 'mock-user', groups: [] })
          return
        }
        const result = await cognitoRequest('InitiateAuth', {
          AuthFlow: 'USER_PASSWORD_AUTH',
          AuthParameters: { USERNAME: email, PASSWORD: password }
        })
        this.setSession(cognitoSession(result))
      } finally {
        this.loading = false
      }
    },

    async register(email, password) {
      return cognitoRequest('SignUp', {
        Username: email,
        Password: password,
        UserAttributes: [{ Name: 'email', Value: email }]
      })
    },

    async confirmRegistration(email, code) {
      return cognitoRequest('ConfirmSignUp', { Username: email, ConfirmationCode: code })
    },

    async resendConfirmation(email) {
      return cognitoRequest('ResendConfirmationCode', { Username: email })
    },

    async getIdToken() {
      if (!this.idToken || config.mocksEnabled || Date.now() < this.expiresAt - 30000) {
        return this.idToken
      }
      if (!this.refreshToken) {
        this.logout()
        throw Object.assign(new Error('Session expired. Please sign in again.'), { code: 'session_expired' })
      }
      if (!this.refreshing) {
        const refreshToken = this.refreshToken
        this.refreshing = cognitoRequest('InitiateAuth', {
          AuthFlow: 'REFRESH_TOKEN_AUTH',
          AuthParameters: { REFRESH_TOKEN: refreshToken }
        })
          .then((result) => {
            if (!this.idToken || this.refreshToken !== refreshToken) {
              throw Object.assign(new Error('Session changed during refresh.'), { code: 'session_expired' })
            }
            this.setSession(cognitoSession(result, refreshToken))
            return this.idToken
          })
          .catch((error) => {
            if (this.refreshToken === refreshToken) { this.logout() }
            throw error
          })
          .finally(() => {
            this.refreshing = null
          })
      }
      return this.refreshing
    },

    setSession({ idToken, email, sub, groups, refreshToken = null, expiresAt = null }) {
      this.idToken = idToken
      this.refreshToken = refreshToken
      this.expiresAt = expiresAt
      this.email = email
      this.sub = sub
      this.groups = groups || []
      setTokenProvider(() => this.getIdToken())
    },

    logout() {
      this.idToken = null
      this.refreshToken = null
      this.expiresAt = null
      this.email = null
      this.sub = null
      this.groups = []
      setTokenProvider(() => null)
    }
  }
})
