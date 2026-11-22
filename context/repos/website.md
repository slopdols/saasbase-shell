# Website Orientation - saasbase

Stack: **Vue 3 SPA (Composition API)**, Pinia, Vue Router 4, vue-i18n v9,
Axios, Vue CLI 5 build, deployed on Vercel.

## Structure

```
website/
+-- vue.config.js           # Webpack customization (Vue CLI 5)
+-- vercel.json             # SPA rewrites + security headers
+-- vercel.sh               # Legacy Git-connected build gate (main | dev)
+-- vitest.config.mjs       # Unit tests (jsdom, coverage targets)
+-- playwright.config.js    # E2E tests (Chromium)
+-- src/
    +-- main.js             # bootstrap (Pinia, router, i18n, analytics)
    +-- config.js           # env-driven app config
    +-- router/index.js     # lazy-loaded routes + auth guard
    +-- stores/             # auth.js, ui.js
    +-- api/client.js       # Axios instance + interceptors + token injection
    +-- mocks/              # full backend mock (ON for `npm run serve`)
    +-- i18n/locales/es.json
    +-- components/         # AppHeader.vue, AppButton.vue
    +-- views/              # Home, Login, Dashboard, NotFound
    +-- analytics/          # first-party analytics placeholder
    +-- utils/              # money.js, format.js, api-errors.js
+-- tests/unit/             # Vitest unit tests
+-- e2e/                    # Playwright E2E (mock-first)
+-- e2e/deployed/           # Real deployed anonymous/native-login checks
```

## Key Patterns

- **Mock-first**: the backend mock intercepts all Axios calls in dev. No
  backend, Cognito, or Stripe needed to develop the UI.
- **Token in memory only**: idToken lives in Pinia state, never localStorage.
- **Money safety**: integer minor units internally; `formatMoney()` divides by
  100 only for display.
- **Lazy routes**: every view is a dynamic `import()`.
- **Error normalization**: API errors arrive as `{code, message, details}`.

## Deployment

See [setup.md](../../setup.md). GitHub deploys the backend before the frontend,
using one Vercel project: main targets Production and dev targets Preview, with
separate AWS backends and stable website URLs. The setup path does
not connect Vercel Git integration or use the legacy ignored-build script.
`setup-scripts/publish-website.ps1` builds with `VUE_APP_API_BASE`,
`VUE_APP_COGNITO_ISSUER` and `VUE_APP_COGNITO_CLIENT_ID` resolved from this
environment's CloudFormation exports. Issuer/client ID are public configuration.
It generates CSP headers allowing exactly the API and Cognito origins, and uploads
only prebuilt public files. Neither the Vercel token nor the automation bypass
secret becomes a frontend build variable. Preview is protected by Vercel
authentication; automated website checks use the dev environment's bypass
header. Production's stable URL remains public. Main/dev pipelines start in parallel;
the first dev upload waits for the Production website to become ready (20 minutes
maximum) so Vercel cannot promote the first Preview to Production. Each website
build receives its stage's exported API endpoint and Cognito configuration automatically.

Native forms support Cognito email/password registration, confirmation-code
verification/resend and login. The auth store keeps ID/refresh tokens only in
memory and refreshes before expiry, sharing a pending refresh between requests.
Logout clears the local session, not sessions on other devices; reload requires
sign-in again. Password reset and MFA challenge screens are not implemented.
Backend JWT signature verification remains authoritative.
Auth/API notifications use the UI store and are rendered by `App.vue`, including
accessible errors and a dismiss button.

Browser auth tests mock Cognito while using the native forms and auth store.
Post-deployment public/API and browser checks run on both environments;
authenticated tests always run on dev, using a temporary non-admin Cognito user,
and require explicit Production opt-in. See [README.md](../../README.md).
Product integrations remain
application-specific work.

## Scripts

```bash
npm run serve          # dev server on :8080 (mocks ON)
npm run build          # production build
npm run test:unit      # vitest
npm run test:e2e       # playwright
npm run test:e2e:auth  # native auth browser flows, mocked Cognito
npm run test:e2e:deployed # live deployment tests, invoked by test-deployment.py
```
