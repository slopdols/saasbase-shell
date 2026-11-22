// Single Axios instance + interceptors + token injection.
// The token provider avoids a circular dependency on Pinia stores.
import axios from 'axios'
import { config } from '@/config'
import { installMock } from '@/mocks'

const api = axios.create({
  baseURL: config.apiBase,
  timeout: 15000
})

let tokenProvider = () => null
export function setTokenProvider(fn) {
  tokenProvider = fn
}

api.interceptors.request.use(async (cfg) => {
  const token = await tokenProvider()
  if (token) cfg.headers.Authorization = `Bearer ${token}`
  return cfg
})

// Error normalization: always reject with a stable { code, message, details } shape.
api.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.code && !error.isAxiosError) { return Promise.reject(error) }
    const normalized = {
      code: 'network_error',
      message: 'Error de red. Inténtalo de nuevo.',
      details: {}
    }
    if (error.response?.data?.error) {
      const { code, message, details } = error.response.data.error
      Object.assign(normalized, { code, message, details })
    }
    return Promise.reject(normalized)
  }
)

if (config.mocksEnabled) {
  installMock(api)
}

export default api
