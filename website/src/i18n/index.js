import { createI18n } from 'vue-i18n'
import es from './locales/es.json'

// CSP-safe: JIT compilation is enabled in vue.config.js (__INTLIFY_JIT_COMPILATION__),
// so messages are compiled to AST and interpreted without eval / new Function.
// Avoid @ (linked-message syntax) in messages; use {name} interpolation only.
export default createI18n({
  legacy: false,
  globalInjection: true,
  locale: 'es',
  fallbackLocale: 'es',
  messages: { es }
})
