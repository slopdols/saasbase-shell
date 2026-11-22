// Errors from the API client are normalized to { code, message, details }.
export function errorMessage(error, fallback = 'Ocurrió un error inesperado') {
  if (error && typeof error.message === 'string' && error.message) {
    return error.message
  }
  return fallback
}
