# SaaS Tech Stack Guide

> **Purpose:** This guide captures the architecture, tooling, and conventions of the **Saasbase** platform - a generic SaaS base shell (FastAPI on AWS Lambda, Vue 3 SPA on Vercel, CloudFormation IaC). It documents how the current project actually works so it can be reused to scaffold future SaaS projects. Ignore the last section of recommendations unless explicitly told.

Use [README.md](../../README.md) for the operating workflow and commands,
[AGENTS.md](../../AGENTS.md) for compact AI context, and
[coding-rules.md](coding-rules.md) for mandatory acceptance requirements.
See [testing.md](testing.md) for the test runbook and
[the developer guide index](README.md) for context classification.
The [handoff prompt](../onboarding/run-this-prompt-after-setup.md) populates
product requirements and approved plans; it does not rebuild this shell.
Optional recommendations below are not implemented or approved architecture.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Infrastructure as Code (IAC)](#infrastructure-as-code-iac)
3. [Backend: FastAPI on AWS Lambda](#backend-fastapi-on-aws-lambda)
4. [CRUD Abstraction Layer](#crud-abstraction-layer)
5. [Frontend: Vue 3 SPA on Vercel](#frontend-vue-3-spa-on-vercel)
6. [CI/CD Pipeline](#cicd-pipeline)
7. [AI-Assisted Development Context](#ai-assisted-development-context)
8. [Branding](#branding)
9. [Testing Strategy](#testing-strategy)
10. [Coding Rules & Conventions](#coding-rules--conventions)
11. [Project Scaffolding Checklist](#project-scaffolding-checklist)
12. [Industry Standard Recommendations](#industry-standard-recommendations)

---

## Architecture Overview

```
+------------------------------------------------------------+
|                      USERS / BROWSERS                       |
+----------+------------------------------+------------------+
           |                              |
           ▼                              ▼
   +--------------+              +----------------+
   |  Vercel (CDN) |              |  API Gateway    |
   |  Vue 3 SPA    |              |  (HTTP API v2)  |
   +--------------+              +-------+----------+
           |                              |
           |                              ▼
           |                     +-----------------+
           |                     |  AWS Lambda      |
           |                     |  FastAPI (Mangum)|
           |                     +----+-------------+
           |                          |
           |              +-----------+-----------+
           |              ▼           ▼           ▼
           |      +----------+ +----------+ +----------+
           |      | DynamoDB | | Cognito  | | Stripe   |
           |      | (4 tables)| | (Auth)   | | (skeleton)|
           |      +----------+ +----------+ +----------+
           |
           ▼
   +----------------+
   |  GitHub Actions |
   |  CI/CD Pipeline |
   +----------------+
```

**Key architectural decisions:**
- **Serverless-first.** Lambda + API Gateway + DynamoDB. Zero server management.
- **Monorepo, independently deployable.** `backend/` and `website/` each deploy separately.
- **Two environments.** Branch `dev` deploys stage `dev`; branch `main` deploys stage `prod`.
- **Container-based Lambda.** Docker image on ECR, not zip uploads. Gives full control over the runtime.
- **Single-table DynamoDB.** All entities in one table with sparse GSIs for flexible queries.
- **Generic shell, not a product.** The only entity today is `item`; `master.py` holds placeholder defaults; `integrations/` (Stripe, SES) are skeletons.
- **Stripe has the last word on money.** Only Stripe webhooks can set `payment_status=paid` (skeleton - not yet implemented).

---

## Infrastructure as Code (IAC)

### Technology Choice

**AWS CloudFormation with nested stacks** - NOT AWS SAM. This gives full control over every resource property (no `AWS::Serverless::*` transform abstractions).

### File Layout

```
iac/
+-- main.yaml                    # Master/orchestrator stack
+-- templates/                   # One file per AWS service
|   +-- cognito.yaml             # User pool, groups, app client, hosted UI
|   +-- dynamodb.yaml            # All tables (main, ledger, throttle, webmetrics)
|   +-- ecr.yaml                 # Container image repository
|   +-- iam.yaml                 # Lambda execution role
|   +-- lambda.yaml              # Lambda function + CloudWatch alarms + SNS
|   +-- apigateway.yaml          # HTTP API (v2) + $default route -> Lambda
|   +-- apidomain.yaml           # Custom domain for API (optional, no-op by default)
|   +-- secrets.yaml             # Secrets Manager placeholder
+-- scripts/
    +-- deploy-stack.sh          # Deploys/updates the master stack (<stage> <phase:1|2>)
    +-- ensure-templates-bucket.sh  # Creates S3 bucket for nested templates
    +-- upload-templates.sh      # Uploads nested YAMLs to S3
    +-- validate-templates.sh    # `aws cloudformation validate-template` on all
    +-- resolve-resource-names.sh   # Emits external resource ARNs as CFN parameter overrides
```

### Master Stack Design (`main.yaml`)

The master stack uses **nested stacks** (`AWS::CloudFormation::Stack`) referencing templates in S3:

```yaml
Resources:
  DynamoDB:
    Type: AWS::CloudFormation::Stack
    Properties:
      TemplateURL: !Sub "https://s3.${AWS::Region}.amazonaws.com/${TemplatesBucket}/${Stage}/templates/dynamodb.yaml"
      Parameters:
        Stage: !Ref Stage
```

**Two-phase provisioning** via a `DeployLambdas` parameter:

| Initial phase 1 (default `DeployLambdas=false`) | Phase 2 (`DeployLambdas=true`) |
|---|---|
| ECR repository | Lambda function (with ECR image) |
| DynamoDB tables | API Gateway + route -> Lambda |
| Cognito user pool + app client | API custom domain mapping |
| IAM execution role | |
| Secrets placeholder; API domain template (no-op) | |

This split exists because the Lambda needs the ECR image to exist before it can be created. Phase 1 provisions all stateful resources first; Phase 2 deploys the compute layer on top.

On subsequent runs phase 1 omits `DeployLambdas` and `ApiImageUri`, preserving
existing compute/image values. Never pass `DeployLambdas=false` to an existing
live stack as an ordinary update or recovery shortcut.

Deploy with `iac/scripts/deploy-stack.sh`:

```bash
./iac/scripts/deploy-stack.sh dev 1   # stateful resources
./iac/scripts/deploy-stack.sh dev 2   # compute (requires API_IMAGE_URI)
```

### Services Configuration Guide

#### DynamoDB Tables

| Table | Purpose | Key Design | Durability |
|---|---|---|---|
| `{app}-main-{stage}` | Core entities (single-table) | `pk`/`sk` + 3 sparse GSIs (`gsi1`/`gsi2`/`gsi3`) | Retain, PITR, deletion protection |
| `{app}-ledger-{stage}` | Ledger storage foundation; payment workflow not implemented | `pk`/`sk`, no GSIs | Retain, PITR, deletion protection |
| `{app}-throttle-{stage}` | Throttle storage foundation | `pk`/`sk`, TTL enabled | Delete on stack removal |
| `{app}-webmetrics-{stage}` | Analytics storage foundation | `pk`/`sk` + 2 GSIs, TTL enabled | Delete on stack removal |

All tables use `BillingMode: PAY_PER_REQUEST` (on-demand). No provisioned capacity.

> **Recovery:** retained/protected resources can outlive failed stacks. Setup
> refuses collisions instead of deleting/reusing them. Use the explicit
> destroy/purge inventory and confirmation for authorized cleanup; do not
> manually remove similarly named resources as a setup workaround.

#### Cognito

- Single user pool per stage: `{app}-pool-{stage}`.
- Website uses native Cognito email/password forms, confirmation/resend and
  token refresh. A hosted domain is provisioned as
  `{app}-{account}-{stage}.auth.<region>.amazoncognito.com`, but the website does
  not implement hosted-UI callback/logout routes.
- Username = email (`UsernameAttributes: [email]`), email auto-verified, standard password policy.
- Two groups: `advertiser`, `admin` (generic placeholders for the shell).
- Public app client `{app}-web-{stage}` (no client secret) allows
  `USER_PASSWORD_AUTH` and `REFRESH_TOKEN_AUTH` for native forms. OAuth code-flow
  scopes are also configured, but no PKCE browser workflow is implemented.
- Callback/logout URLs are set **only** when `WebsiteUrl` is provided (Cognito rejects scheme-less URLs, so the default `''` is guarded by a condition).
- No Google/IdP federation yet. No post-confirmation Lambda trigger (the `advertiser` group description mentions one, but no trigger resource is defined).

#### Lambda

- **Runtime:** Container image from ECR (`FROM public.ecr.aws/lambda/python:3.13`).
- **Architecture:** x86_64, 1024 MB RAM, 15s timeout.
- **Handler:** Mangum wrapping FastAPI (`api.main.handler`).
- **Env vars injected by CloudFormation:** `SAASBASE_ENVIRONMENT`, `SAASBASE_DB_BACKEND`, `SAASBASE_REGION`, the four table names, Cognito pool ID / issuer / audience / JWKS URL, secrets ARN, admin sub, CORS origins.
- **Log group:** `/aws/lambda/{app}-api-{stage}`, 14-day retention.
- **Alarms:** Errors (>=1 in 5 min), Throttles (>=1 in 5 min), p99 Duration (>=2s in 5 min). All -> SNS topic `{app}-alerts-{stage}`.
- **X-Ray tracing:** enabled (`TracingConfig: Active`).

#### API Gateway

- **Type:** HTTP API (API Gateway v2). Lower latency, cheaper than REST API.
- **Route:** `$default` catches all paths -> integrated to Lambda.
- **Auth:** None at the API Gateway layer. JWT verification happens in FastAPI.
- **Throttle:** 50 burst, 100 rate per second (adjustable).
- **Custom domain:** Optional, requires an ACM certificate provisioned out-of-band (the mapping is commented out by default).

#### IAM

**Lambda execution role** - tight data-plane permissions:
- DynamoDB item/query/batch permissions on specific table ARNs.
  Transactions use the corresponding item permissions; `TransactWriteItems`
  is not a valid IAM action.
- `cognito-idp:AdminGetUser` on the user pool.
- `secretsmanager:GetSecretValue` on the secrets ARN.
- `ses:SendEmail/SendRawEmail` on the verified domain identity.
- `logs:CreateLogStream/PutLogEvents` on the log group.
- `cloudwatch:PutMetricData` for EMF metrics.
- `xray:PutTraceSegments/PutTelemetryRecords` for tracing.

**CI/CD deploy role** (defined in `aws/iam.json` + `aws/trust-policy.json`):
- OIDC-federated from GitHub Actions (no long-lived credentials). Role name
  `{app}-{GitHub-repository-ID}-github-deploy`; inline policy `{app}-deploy`.
- CloudFormation runs **as this role**, so the policy includes the service-management actions for EVERY resource the nested stacks create (not just pass-role). Missing permissions -> `CREATE_FAILED` + `ROLLBACK_FAILED` (e.g. `iam:GetRole`/`iam:DeleteRolePolicy` denied on `saasbase-lambda-*`).
- The policy covers stack management, application data-plane resources and
  temporary Cognito test users. Setup scopes supported ARNs to the selected
  app/account/region; some service-management actions require broader resources.
  Consult `aws/iam.json` and the generated policy, not a static role-name example.
- Must include `cloudformation:GetTemplateSummary` - `aws cloudformation deploy` calls it internally and fails with AccessDenied (exit 254 in CI) without it.
- `ensure-templates-bucket.sh` only needs `s3:ListBucket` for `head-bucket` (same account); `s3:HeadBucket` is not required.

#### Secrets Manager

- One app secret placeholder, `{app}-app-secrets-{stage}-v4`. Product-specific
  keys and their runtime consumers must be designed and implemented explicitly.
- Created as `{}` placeholder by CloudFormation with `DeletionPolicy: Retain`. Real value populated **out-of-band** (manual or CI script).
- Setup rejects existing application resource names, including retained secrets.
  Choose another app name; do not automatically bump suffixes to hide collisions.
  Explicit destroy/purge can permanently remove app secrets.

### Environment/Stage Separation

Every resource name is suffixed with `{stage}`:
- `dev` branch -> `<resource>-dev`
- `main` branch -> `<resource>-prod`

Parameters flow from CI/CD into the master stack:
```
aws cloudformation deploy \
  --parameter-overrides \
    Stage=$STAGE \
    ApiImageUri=$ECR_IMAGE_URI \
    WebsiteUrl=$WEBSITE_URL \
    AdminSub=$ADMIN_SUB \
    ...
```

---

## Backend: FastAPI on AWS Lambda

### Core Pattern: One Codebase, Two Runtimes

The **same FastAPI `app` object** runs both locally and on Lambda:

```python
# api/main.py
from fastapi import FastAPI
from mangum import Mangum

app = FastAPI()

# ... routers, middleware, exception handlers ...

handler = Mangum(app)  # ASGI -> Lambda adapter (only used on AWS)
```

- **Local:** `uvicorn api.main:app --reload`
- **Lambda:** The `handler` callable is invoked by the Lambda runtime

### Middleware Stack (inside-out)

1. **Error boundary** - Single place where all exceptions are caught and translated to HTTP responses. Three handlers:
   - `AppError` (domain error) -> its HTTP status + `{"error": {"code": "...", "message": "..."}}` envelope
   - `RequestValidationError` (Pydantic) -> 422 with validation details
   - `Exception` (unhandled) -> 500, logged error and best-effort Telegram alert
     when configured. SNS receives Lambda alarms; it is not this alert helper.
2. **Metrics middleware** - Emits CloudWatch EMF JSON for returned responses:
   method, route template, status, latency. Unmatched routes currently fall back
   to the raw path; do not claim bounded cardinality for that fallback.
3. **CORS middleware** - Outermost. Echoes `Access-Control-Allow-Origin` for configured origins. Preflight short-circuits.

### Directory Structure

```
backend/
+-- pyproject.toml              # Black(100), Ruff(E,F,I,W,UP,B), mypy strict, pytest
+-- requirements-dev.txt        # Dev dependencies (pytest, moto, httpx, ruff, black, mypy)
+-- api/
    +-- main.py                 # FastAPI app, error boundary, middleware, Mangum handler
    +-- config.py               # Pydantic BaseSettings, env prefix SAASBASE_
    +-- master.py               # Business-critical defaults (generic placeholders)
    +-- Dockerfile              # Lambda container image build
    +-- requirements.txt        # Runtime dependencies
    +-- auth/                   # JWT verification, device auth, dependencies
    |   +-- cognito.py          # Cognito JWKS fetch + RS256 verification
    |   +-- caller.py           # Caller dataclass + authz helpers
    |   +-- deps.py             # FastAPI Depends() injectors
    |   +-- device.py           # Device token auth (HMAC)
    |   +-- anon.py             # Anonymous session tokens
    |   +-- signing.py          # HMAC/Fernet token primitives
    +-- routers/                # Thin HTTP handlers (health, auth, items)
    +-- services/               # Business logic (items.py)
    +-- crud/                   # Data access layer
    |   +-- crud.py             # Public API (get/put/update/delete/query/query_index/...)
    |   +-- backend_flag.py     # Pluggable backend factory (Dynamo | Relational)
    |   +-- dynamo_crud.py      # DynamoDB implementation
    |   +-- relational_crud.py  # Future SQL implementation (NotImplementedError)
    |   +-- models.py           # Entity types (item), new_item(), primary_key()
    +-- schemas/                # Pydantic request/response models
    +-- integrations/           # Stripe (skeleton), SES email (skeleton)
    +-- core/                   # Shared utilities (alerts, errors, logging, metrics, money, time)
```

### Config System

Three-layer hierarchy:

1. **`api/master.py`** - Placeholder product constants, not completed pricing or
   limit enforcement. Inspect actual consumers before assuming a constant is
   configurable or active; do not invent corresponding environment fields.
2. **`api/config.py`** - `Settings(BaseSettings)` class. Every field maps to a `SAASBASE_<NAME>` env var or `.env` file entry. Groups: environment, CORS, API, data stores, auth (Cognito), auth (device/anon tokens), Stripe, email, alerts, secrets.
3. **Environment / Secrets Manager** - Settings read environment variables.
   CloudFormation injects backend configuration into Lambda. A Secrets Manager
   ARN/placeholder exists, but runtime retrieval and injection are not implemented.
   Locally, use `config/.env` with
   `uvicorn api.main:app --reload --env-file ../config/.env` from `backend`.
   `Settings` also supports a `.env` in the current working directory.

```python
# config.py
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SAASBASE_", env_file=".env")

    environment: str = "local"
    db_backend: Literal["dynamo", "relational"] = "dynamo"
    region: str = "us-east-2"
    cors_origins: list[str] = ["http://localhost:8080"]
    api_prefix: str = "/v1"
    table_main: str = "saasbase-main-dev"
    table_ledger: str = "saasbase-ledger-dev"
    table_throttle: str = "saasbase-throttle-dev"
    table_webmetrics: str = "saasbase-webmetrics-dev"
    # cognito_*, device_token_key, fernet_key, stripe_*, email_from,
    # alert_telegram_*, secrets_arn ...

@lru_cache
def get_settings() -> Settings:
    return Settings()
```

### Auth System

**Two authentication mechanisms:**

| Mechanism | Where Used | How |
|---|---|---|
| **Cognito JWT** (RS256) | Website | JWKS fetch (cached 1h), verify signature/issuer/audience/expiry/token_use |
| **Device Token** (HMAC) | Non-browser clients (skeleton) | 32-byte random token, HMAC-SHA256 hashed for lookup, Fernet-encrypted for reveal |

**FastAPI dependency injection:**
```python
caller: Caller = Depends(require_caller)       # JWT required
caller: Caller | None = Depends(optional_caller)  # JWT optional
caller: Caller = Depends(require_admin)         # JWT + admin group
device: dict = Depends(require_device)           # X-Device-Token header
```

**Authorization helpers:** `require_group(caller, group)` and
`require_owner(caller, owner_sub)` allow an admin bypass within those helpers.
Do not infer a universal admin override: the sample item service independently
enforces ownership. The `Caller` dataclass carries `sub`, `email`, `groups`,
`is_anonymous`, and an `is_admin` property.

### Router -> Service -> CRUD Pattern

Routers are **thin** - validate with Pydantic, call a service, return shaped response:

```python
@router.post("/v1/items", status_code=201, response_model=ItemView)
def create_item(body: ItemCreate, caller: Caller = Depends(require_caller)) -> dict:
    return items_service.create_item(caller.sub, body.name)
```

Services contain **all business logic**. They orchestrate CRUD + integrations. Errors propagate to the `main.py` boundary.

### Dockerfile for Lambda

```dockerfile
FROM public.ecr.aws/lambda/python:3.13
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN python -m pip install --upgrade pip && \
    python -m pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt
COPY . ${LAMBDA_TASK_ROOT}/api/
CMD ["api.main.handler"]
```

### Key Dependencies

| Package | Purpose |
|---|---|
| `fastapi` (0.115) | Web framework |
| `mangum` (0.19) | ASGI -> AWS Lambda adapter |
| `pydantic` (2.11) / `pydantic-settings` | Models + settings from env vars / .env |
| `boto3` | AWS SDK (DynamoDB, SES, Secrets Manager) |
| `pyjwt[crypto]` (2.10) | Cognito JWT verification (RS256) |
| `cryptography` | Fernet encryption for device tokens |
| `httpx` | Async HTTP for Telegram alerts |

Local dev runs `uvicorn api.main:app --reload --env-file ../config/.env` from
`backend`, but `uvicorn` is **not** pinned in `requirements-dev.txt` (install it
separately). `integrations/stripe.py` imports the `stripe` SDK, but it is not yet
a declared runtime dependency - add it when Stripe flows are implemented.

### Dev Dependencies

| Package | Purpose |
|---|---|
| `pytest`, `pytest-cov`, `pytest-xdist` | Test runner + coverage + parallel |
| `moto[dynamodb,secretsmanager]` | AWS service mocking |
| `httpx` | FastAPI TestClient async transport |
| `ruff`, `black`, `mypy` | Linting, formatting, type checking |

---

## CRUD Abstraction Layer

### Design Goal

Abstract away whether the database is DynamoDB or a relational database (PostgreSQL/MySQL). The rest of the codebase never knows which backend is active.

### Three-Layer Architecture

```
Services/Routers
       |
       ▼
   crud.py          <- Public API: get_resource(), put_resource(), update_resource(),
                       delete_resource(), query_resources(), query_index(),
                       batch_get_resources(), transact_write(), touch_resource()
       |
       ▼
 backend_flag.py    <- @lru_cache factory (get_crud()): reads settings.db_backend ->
                       returns DynamoCrud() or RelationalCrud()
       |
       ▼
+----------+  +---------------+
|DynamoCrud|  |RelationalCrud |
|(active)  |  |(placeholder)  |
+----------+  +---------------+
```

### Public CRUD API (`crud.py`)

| Function | Purpose |
|---|---|
| `get_resource(pk, sk)` | Fetch a single item by primary key |
| `put_resource(item)` | Create a new item (fails if exists) |
| `update_resource(pk, sk, updates, expected_version)` | Atomic update with optimistic locking |
| `delete_resource(pk, sk)` | Soft delete (set `status="deleted"`) |
| `query_resources(pk, sk_prefix, limit, cursor)` | Collect all range-query pages; `limit` is the database batch size |
| `query_index(index_name, pk, sk_prefix, limit, cursor)` | Collect all sparse GSI pages (`gsi1`/`gsi2`/`gsi3`) by pk/sk |
| `batch_get_resources(keys)` | Bulk fetch (collapses N+1 into BatchGetItem) |
| `transact_write(operations)` | Atomic multi-item write (all-or-nothing) |
| `touch_resource(pk, sk, updates)` | Update without optimistic locking (non-critical fields) |

### DynamoDB Implementation Details

- **Single-table design:** `pk = ENTITY#<id>`, `sk = ENTITY#<id>` for top-level items. Ledger uses `pk = ACCOUNT#<type>#<id>`, `sk = LEDGER#<ts>#<id>`.
- **Optimistic locking:** `update_resource()` requires `expected_version`. DynamoDB condition expression: `#v = :expected`. Conflict -> `ConflictError`.
- **Soft delete:** Never physically removes rows. Sets `status = "deleted"`.
- **Number handling:** DynamoDB returns `Decimal`; CRUD normalizes to `int`.
- **Pagination:** Base64url-encoded JSON of `LastEvaluatedKey`.
- **GSI query patterns:** 3 sparse GSIs (`gsi1`/`gsi2`/`gsi3`) for flexible access patterns.
- **RelationalCrud** raises `NotImplementedError` on every method so a misconfigured backend fails loudly instead of silently corrupting data.

### Standard Entity Columns

Every item has `pk`, `sk`, `entity_type`, `id`, `created_at`, `updated_at`,
`status` and `version` (starts at 0). The builder includes optional GSI columns;
CRUD omits unused `None` index keys from DynamoDB records to preserve sparse
indexes rather than writing invalid `NULL` index values.

### How to Add a New Entity

1. Add the entity name to `ENTITY_TYPES` in `models.py` (currently only `item` is registered).
2. Use `new_item(entity_type, entity_id, **fields)` to construct items - it fills all standard columns.
3. Set GSI keys for each query pattern you need.
4. Write CRUD calls using the public API - they dispatch to the active backend automatically.

---

## Frontend: Vue 3 SPA on Vercel

### Technology Stack

| Layer | Choice |
|---|---|
| Framework | Vue 3 (Composition API) |
| State | Pinia |
| Routing | Vue Router 4 (HTML5 history mode) |
| i18n | vue-i18n v9 (JIT / CSP-safe compiler) |
| HTTP | Axios (single instance + interceptors) |
| Auth | Native Cognito registration/confirmation/login/refresh; mock-first local mode |
| Unit tests | Vitest + jsdom |
| E2E | Playwright (Chromium, mock-first) |
| Build | Vue CLI 5 (`@vue/cli-service`) |
| Deploy | Vercel (static + SPA rewrites) |

### Directory Structure

```
website/
+-- package.json             # Dependencies + scripts
+-- vue.config.js            # Webpack customization (i18n JIT compilation)
+-- vercel.json              # SPA rewrites + security headers
+-- vercel.sh                # Conditional build (main/dev branches)
+-- vitest.config.mjs        # Unit test config + coverage targets
+-- playwright.config.js     # E2E test config
+-- babel.config.js
+-- jsconfig.json            # Path alias '@' -> src/
+-- src/
|   +-- main.js              # App bootstrap (Pinia, router, i18n, analytics)
|   +-- App.vue
|   +-- config.js            # Env-driven app config (apiBase, mocksEnabled)
|   +-- router/index.js      # Lazy-loaded routes + auth guard
|   +-- stores/              # Pinia stores (auth, ui)
|   +-- api/
|   |   +-- client.js        # Axios instance + interceptors + token injection
|   +-- mocks/               # Complete backend mock for local dev
|   |   +-- index.js         # Route table + axios adapter (items + auth/me)
|   |   +-- auth.js          # Mock auth
|   |   +-- responses/       # JSON fixtures
|   +-- composables/         # Vue composables (useMeta, useStatusLabel)
|   +-- components/          # Reusable UI components (AppHeader, AppButton)
|   +-- views/               # Page-level components (Home, Login, Dashboard, NotFound)
|   +-- i18n/
|   |   +-- index.js          # vue-i18n setup (CSP-safe JIT compiler)
|   |   +-- locales/es.json   # Spanish-only locale
|   +-- analytics/           # First-party analytics placeholder
|   +-- utils/               # money.js, format.js, api-errors.js
+-- tests/
|   +-- setup.js             # Global test setup
|   +-- unit/                # Vitest unit tests
+-- e2e/
|   +-- helpers.js           # fakeJwt(), stubAnalytics(), stubStripe(), dismissConsent()
|   +-- *.spec.js            # Playwright E2E tests
+-- public/
    +-- index.html
```

### Vercel Configuration

**`vercel.json` - Source configuration:**

1. **SPA rewrites:** `{"source": "/(.*)", "destination": "/index.html"}` - all paths serve the SPA shell.
2. **Legacy Git-connected commands:** `npm run build` and `bash ./vercel.sh`;
   these are not the onboarding deployment path.
3. **Security headers** on every response:
   ```
   Content-Security-Policy: strict (default-src 'self'; script-src 'self'; no 'unsafe-eval')
   X-Frame-Options: DENY
   X-Content-Type-Options: nosniff
   Referrer-Policy: strict-origin-when-cross-origin
   Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
   Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(self)
   ```

**Current publishing:** `setup-scripts/publish-website.ps1` builds in GitHub
Actions and uploads Build Output API v3 artifacts. It preserves source security
headers, inserts exact API/Cognito CSP origins and generates SPA routing.
Only public files are uploaded. Production uses main; protected Preview uses dev.
GitHub's planner reads `config/override.env`; do not connect Vercel Git integration
or depend on the legacy `vercel.sh` ignored-build step.

### API Client Pattern

Reuse `website/src/api/client.js`: shared Axios configuration, token-provider
injection, authenticated request handling and error normalization. The auth store
owns native Cognito sign-in/refresh and shares pending refresh requests.
UI notifications use the existing UI store. Do not copy a simplified HTTP client
into each feature or introduce persistent token storage.

### Mock-First Development

The `website/src/mocks/` directory provides a **complete backend mock**:
- Axios adapter interception matches `[method, regex]` pairs against the item CRUD routes + `/v1/auth/me`.
- Returns JSON fixtures with 150ms artificial latency.
- Mock auth flips a flag - no real Cognito needed.
- **On by default for `vue-cli-service serve`**, off for production builds.
  Local browser suites explicitly exercise mock and native-auth fixture modes.

This enables shell UI development without running AWS services. Product mocks
must evolve with the real API; they do not prove Cognito, Stripe or other
external integrations work.

### Key Design Patterns

- **Code splitting:** Every route is a dynamic `import()` - views are never in the main bundle.
- **Money safety:** All internal math in integer minor units. `formatMoney()` divides by 100 only for display.
- **CSP-safe i18n:** JIT compilation enabled in `vue.config.js` (`__INTLIFY_JIT_COMPILATION__`) so messages compile to an AST - no `eval()` / `new Function()`. Use `{name}` interpolation only (avoid linked-message syntax).
- **Auth guard:** Protected routes (meta `requiresAuth`) redirect to `/login` when unauthenticated. Admin-only routing is not implemented yet.
- **Token in memory only:** The idToken lives in Pinia state (memory), never in localStorage.

---

## CI/CD Pipeline

### Branch Strategy

```
main  -------------------------------------►  (production: selected backend, Vercel prod)
  |
  +-- dev  ---------------------------------►  (development: selected backend, Vercel preview)
```

There is no automatic synchronization or promote job. Setup starts main/dev
pipelines in parallel and requires both to pass; only the first Preview upload
waits for a ready Production website. Later changes follow the reviewed branch workflow.
Pull requests test but do not deploy.

### Pipeline Stages (GitHub Actions - `.github/workflows/ci-cd.yml`)

| Stage | When | What |
|---|---|---|
| **Check changes and overrides** | Push/PR to `main`/`dev`, dispatch; first job | Resolve changed infrastructure/components and explicit deployment/test flags |
| **Offline gates** | After changes job; all enabled by default | Infrastructure/script tests and schema lint, full backend suite, frontend unit and both local browser suites |
| **Deploy Backend** | Backend selected; enabled tests passed | OIDC role, build/push image, managed image update; validation/phase 1/uploads only for IaC changes or full deployment |
| **Deploy Website** | Website selected | Resolve API/Cognito exports, build public artifacts, publish through Vercel API, verify headers/routing |
| **Test deployed website and API** | Separate job after selected deployment; enabled by default | Public API/browser checks; temporary-user auth required on dev when it runs and opted-in on prod |

Notes on the current pipeline:
- Changes and overrides are resolved before test jobs. Explicit skips are
  surfaced as warnings and do not prove acceptance.
- `setup-scripts/resolve-deploy-plan.sh` reads `config/override.env` without sourcing or executing it. Only the documented boolean flags are accepted; malformed or duplicate entries fail the workflow.
- By default, backend paths deploy the backend and website paths deploy the website. `SKIP_ALL` skips deployment; otherwise `FORCE_ALL` deploys both; per-stage skip/force flags override path detection. A skipped backend is health-checked from its existing CloudFormation endpoint when the website is deployed.
- GitHub builds and uploads Vercel artifacts. Vercel Git integration is not
  connected; there is no separate release branch.
- Initialization commits use `[skip ci]`; setup dispatches the configured
  pipeline explicitly and waits for full main/dev deployments.
- Setup creates an empty private repo, preserves the cloned shell's history and
  initializes both branches at the skipped commit. It does not use GitHub's
  template-generation API/metadata, which previously created extra initial runs.
- The live job installs website dependencies/browser runtime even after
  backend-only deployments because the existing website receives real checks.
  Skipping that job avoids its runtime installs. Frontend deployment dependencies
  install only when the website is selected.
- Backend-only changes skip phase 1 and template uploads. The image-only phase 2
  preserves non-image parameters and tracks the new image through CloudFormation,
  avoiding direct Lambda image drift. Initial/manual runs and `FORCE_ALL` use both phases.

### `config/override.env` - Pipeline Control

```bash
# Skip all deployments (highest precedence)
SKIP_ALL=true

# Force all stages to run regardless of change detection
FORCE_ALL=true

# Or skip specific stages
SKIP_DEPLOY_BACKEND=true
SKIP_DEPLOY_WEBSITE=true

# Or force specific stages
FORCE_DEPLOY_BACKEND=true
FORCE_DEPLOY_WEBSITE=true

# Independently skip tests (all default false)
SKIP_TEST_INFRASTRUCTURE=true
SKIP_TEST_BACKEND=true
SKIP_TEST_WEBSITE_UNIT=true
SKIP_TEST_WEBSITE_E2E=true
SKIP_TEST_WEBSITE_AUTH=true
SKIP_POST_DEPLOY_TESTS=true
```

Precedence: `SKIP_ALL > FORCE_ALL > per-stage flags > change detection`. Use one
`KEY=true` or `KEY=false` setting per line; duplicate, unknown, or non-boolean
entries fail the workflow. Setting both skip and force for the same stage also
fails. `SKIP_ALL` and `FORCE_ALL` override per-stage flags.
They control deployment, not tests. Explicit test skips are independent, reported
as unverified, and rejected by initial setup. Local full-suite acceptance ignores them.

### AWS Authentication

- **OIDC federation** - GitHub Actions assumes
  `{app}-{GitHub-repository-ID}-github-deploy`, with no long-lived AWS credentials.
- Setup generates trust for the specific repository and `prod`/`dev` GitHub
  environments; `aws/trust-policy.json` is an example, not the final policy.
- Setup renders `aws/iam.json` for the selected app/account/region. Temporary-user
  tests use only the environment's exported Cognito pool.

### Test Gates

- Run all local suites/build/schema checks with `./scripts/test.ps1` or
  `bash ./scripts/test.sh` before handoff. No pre-push hook replaces acceptance.
- CI runs all offline suites by default after deployment/test selection.
  Per-suite skips are explicit user choices, not substitutes for full local acceptance.
- Auth-matrix tests cover missing/invalid identity, roles and ownership.
- Authenticated live checks use a temporary non-admin user on dev; prod requires
  `RUN_AUTH_SMOKE_TESTS=true`. Cleanup failures fail the run. Mocked tests are not
  live evidence; automatic user creation does not test inbox email delivery.

---

## AI-Assisted Development Context

### The Three-Layer Knowledge System

This codebase is designed for AI agents to work on it efficiently. Three artifacts work together:

1. **`AGENTS.md`** - The compact repository instruction entry point. Defines
   product context, implementation map, commands, invariants and document links.
2. **`context/` folder** - The knowledge base. Authoritative documents for what the product should do and how to implement it.
3. **Test suite** - The executable specification. Tests assert behavior, not implementation details.

### `context/` Folder Structure

```
context/
+-- business_logic/                 # Source of truth for product behavior
|   +-- README.md                   # Placeholder - add one doc per business area
+-- dev_guides/                     # Implementation guides
|   +-- coding-rules.md             # 8 coding principles
|   +-- README.md                   # Developer guide index and context map
|   +-- testing.md                  # Test ownership, commands and live isolation
|   +-- ci-cd-issues.md             # CI gate troubleshooting
|   +-- aws-cli-resource-explorer.md # Read-only AWS CLI field guide
|   +-- iam-issues.md               # IAM AccessDenied fixes
|   +-- aws-admin-cloudshell.md     # AWS admin commands from CloudShell
|   +-- saas-techstack-guide.md     # Full stack guide (this document)
+-- onboarding/                     # First-use application handoff
|   +-- run-this-prompt-after-setup.md
+-- plans/                          # Forward-looking designs (not implemented)
|   +-- README.md                   # RFC-style designs go here
|   +-- idea.md                     # (empty - original product vision TBD)
+-- repos/                          # Per-repo orientation summaries
    +-- backend.md                  # Stack, structure, endpoints, conventions
    +-- website.md                  # Vue 3 SPA structure, views, stores
    +-- aws-infra.md                # Infrastructure overview, nested stacks
```

### Conflict Resolution Rule

If a business-logic document and the code disagree:
1. **Report the conflict** explicitly.
2. Code is authoritative for *current behavior*.
3. Document is authoritative for *intended behavior*.
4. Do not "fix" one to match the other without asking.

### `AGENTS.md` Template

Use the checked-in [AGENTS.md](../../AGENTS.md), not a second copied template.
Keep it compact: product context, links, implementation map, full-suite commands,
deployment policy and invariants. Populate product details through the
[handoff prompt](../onboarding/run-this-prompt-after-setup.md); requirements live
in `context/business_logic/`, approved plans in `context/plans/`. Preserve shared
engineering rules when adding product context.

---

## Branding

### Purpose

The `brand/` folder centralizes all brand assets so they're accessible to both human developers and AI agents:

```
brand/
+-- branding.md                # Brand guidelines (naming + env/resource prefixes)
+-- logo/                      # Logo variants (empty - no assets generated yet)
```

- **`branding.md`** currently defines the naming conventions: product **Saasbase**, env prefix `SAASBASE_`, resource prefix `saasbase-`. Tagline, core attributes, and voice are TBD.
- `brand/logo/` is empty - add `all_black.png`, `all_white.png`, `dark.png`, `light.png` as they are created.

---

## Testing Strategy

### Three Test Layers

| Layer | Scope | Framework | Acceptance |
|---|---|---|---|
| **Unit** | Individual functions, services, auth, schemas and frontend state/client | pytest / Vitest | Meaningful behavior and failure cases |
| **Functional** | Cross-service flows through real FastAPI app | pytest + TestClient + mocked AWS | Behavior verification |
| **Browser (local)** | UI/mock workflows and native-auth forms | Playwright, mocked backend/Cognito | User-visible workflow/error checks |
| **Integration/browser (live)** | Real configured Cognito, API and website | Python orchestration, PowerShell API checks, Playwright | Mandatory authenticated dev checks; prod opt-in |

### Backend Test Structure

```
backend/tests/
+-- conftest.py              # Shared fixtures: env setup, mock DynamoDB (moto), stubbed JWKS, TestClient, make_jwt
+-- core/                    # money, time
+-- crud/                    # DynamoDB CRUD ops
+-- routers/                 # health, items + test_auth_matrix (security gate)
+-- services/                # item service logic
```

The `conftest.py` sets `SAASBASE_*` env vars before importing the app, spins up fresh moto DynamoDB tables per test, stubs the Cognito JWKS client with a locally-minted RSA key, and exposes `make_jwt()` + `ApiEnv` for tests.

### Test Runners

```bash
# full acceptance, from repository root
bash ./scripts/test.sh

# focused backend feedback, from backend
python -m pytest --import-mode=importlib

# focused frontend feedback, from website
npm run test:unit
npm run test:e2e
npm run test:e2e:auth
```

PowerShell uses `./scripts/test.ps1`. The full runner also includes script suites,
frontend production build and CloudFormation schema lint. Coverage can help find
gaps, but current CI does not enforce the historical 90% coverage command.
It must not substitute for unit/API/browser acceptance.

### Auth Matrix Test

A dedicated test (`tests/routers/test_auth_matrix.py`) must fail if any route is under-protected. This is a critical security gate.

### Frontend Testing

- **Unit:** Vitest + jsdom, in `website/tests/unit/`. Optional coverage settings
  do not change the requirement to verify observable behavior.
- **Local E2E:** Playwright Chromium in `website/e2e/`; the separate native-auth
  config verifies forms, refresh and failures with mocked Cognito responses.
- **Deployed E2E:** `website/e2e/deployed/`, with no mocked network responses.
  The Python runner forces authenticated mode on dev, creates/masks temporary
  credentials and removes the user afterward. Record forced-cleanup limits.
- Every applicable feature needs unit, API/integration and browser tests.
  New suites must join CI and the full runner; do not add uninvoked test folders.

---

## Coding Rules & Conventions

### 1. Simplicity
Write the simplest code that solves the problem. No speculative abstractions, no premature optimization. Delete dead code.

### 2. Single-Purpose Functions
Every function does one thing. Name it for that one thing. No hidden side effects.

### 3. Errors Propagate
Unexpected errors bubble up to the entry point. Never catch-and-swallow. Catch only when you can fully handle the error. One error boundary at the top.

### 4. No Retry Nests
Retry logic in at most one place per outbound call. Always bounded. Prefer no retry.

### 5. Validate at Boundaries Only
Validate input where it enters the system (schemas, route guards). Do not re-validate inside. Trust internal callers.

### 6. Test-Driven
Every feature ships with tests covering happy path and all edge/error cases. Tests assert behavior, not implementation details.

### 7. No Secrets in Code
Secrets come from env / AWS Secrets Manager. Never committed to git. Use `.env.example` templates.

### 8. Money and Time
- **Money:** integer minor units (centavos/cents) + ISO-4217 currency code. **Never floats.**
- **Time:** ISO-8601 UTC strings (e.g. `2026-06-22T14:03:51.123456+00:00`). They sort lexicographically.

### Python-Specific Conventions

| Tool | Config |
|---|---|
| **Black** | Line length 100, target Python 3.13 |
| **Ruff** | Rules: `E, F, I, W, UP, B`. Ignore: `B008` (FastAPI `Depends()`) |
| **mypy** | Strict: `disallow_untyped_defs = true`, `no_implicit_optional = true` |
| **Imports** | Sorted via Ruff (isort-compatible) |

---

## Project Scaffolding Checklist

Historical from-scratch checklist, not onboarding instructions. These components
already exist in this shell: use root setup once, then the handoff prompt and
approved feature plans. Do not recreate resources or replace the stack merely
because a checklist or optional recommendation mentions it.

### Phase 1: Repository Setup
- [ ] Create monorepo with `backend/`, `website/`, `iac/`, `context/`, `brand/` root folders
- [ ] Create `AGENTS.md` at the root (repository instructions for AI agents)
- [ ] Create `context/` with `business_logic/`, `dev_guides/`, `plans/`, `repos/` subdirectories
- [ ] Create `context/dev_guides/coding-rules.md` with the 8 coding principles
- [ ] Create `context/dev_guides/saas-techstack-guide.md` (this document)
- [ ] Create `brand/branding.md` and `brand/logo/` directory
- [ ] Create `.gitignore` (exclude `.env`, `node_modules`, `__pycache__`, binaries)
- [ ] Create `config/.env.example` (SAASBASE_* env template)
- [ ] Create `config/override.env` with pipeline control flags

### Phase 2: IAC
- [ ] Create `iac/main.yaml` - master CloudFormation stack with two-phase provisioning
- [ ] Create `iac/templates/` - one template per service:
  - [ ] `dynamodb.yaml` - 4 tables (main single-table, ledger, throttle, webmetrics)
  - [ ] `cognito.yaml` - user pool, groups, app client
  - [ ] `ecr.yaml` - container image repository
  - [ ] `iam.yaml` - Lambda execution role
  - [ ] `lambda.yaml` - Lambda function + CloudWatch alarms + SNS
  - [ ] `apigateway.yaml` - HTTP API v2 + `$default` route
  - [ ] `apidomain.yaml` - custom domain (optional no-op)
  - [ ] `secrets.yaml` - Secrets Manager placeholder
- [ ] Create `iac/scripts/` - deploy, validate, upload, resolve-resource-names
- [ ] Create `aws/iam.json` - CI/CD deploy role IAM policy
- [ ] Create `aws/trust-policy.json` - OIDC trust policy

### Phase 3: Backend
- [ ] Create `backend/pyproject.toml` - Black, Ruff, mypy, pytest config
- [ ] Create `backend/requirements-dev.txt` - dev dependencies
- [ ] Create `backend/api/requirements.txt` - runtime dependencies
- [ ] Create `backend/api/Dockerfile` - Lambda container image
- [ ] Create `backend/api/main.py` - FastAPI app + Mangum handler + error boundary + middleware
- [ ] Create `backend/api/config.py` - Pydantic BaseSettings (SAASBASE_ prefix)
- [ ] Create `backend/api/master.py` - business-critical defaults
- [ ] Create `backend/api/auth/` - Cognito JWT, device auth, signing, dependencies
- [ ] Create `backend/api/routers/` - thin HTTP handlers (health, auth, items)
- [ ] Create `backend/api/services/` - business logic
- [ ] Create `backend/api/crud/` - pluggable data access layer
  - [ ] `crud.py` - public API
  - [ ] `backend_flag.py` - factory
  - [ ] `dynamo_crud.py` - DynamoDB implementation
  - [ ] `relational_crud.py` - future SQL placeholder (NotImplementedError)
  - [ ] `models.py` - entity types, standard column builder
- [ ] Create `backend/api/schemas/` - Pydantic request/response models
- [ ] Create `backend/api/integrations/` - Stripe, email skeletons
- [ ] Create `backend/api/core/` - shared utilities
- [ ] Create `backend/tests/` - mirror the api/ structure
  - [ ] `conftest.py` - shared fixtures (moto, JWKS, TestClient)
  - [ ] `test_auth_matrix.py` - route protection verification

### Phase 4: Frontend
- [ ] Create `website/package.json` - Vue 3, Pinia, Vue Router, vue-i18n, Axios
- [ ] Create `website/vue.config.js` - Webpack customization (i18n JIT compilation)
- [ ] Create `website/vercel.json` - SPA rewrites + security headers
- [ ] Create `website/vercel.sh` - conditional build script (main/dev)
- [ ] Create `website/vitest.config.mjs` - Vitest config with coverage targets
- [ ] Create `website/playwright.config.js` - E2E config
- [ ] Create `website/src/main.js` - app bootstrap
- [ ] Create `website/src/config.js` - env-driven app config
- [ ] Create `website/src/router/index.js` - lazy-loaded routes + guards
- [ ] Create `website/src/stores/` - Pinia stores (auth, UI)
- [ ] Create `website/src/api/client.js` - Axios instance + interceptors
- [ ] Create `website/src/mocks/` - complete backend mock for local dev
- [ ] Create `website/src/composables/` - Vue composables
- [ ] Create `website/src/components/` - reusable components
- [ ] Create `website/src/views/` - page components (lazy-loaded)
- [ ] Create `website/src/i18n/` - vue-i18n + locale file
- [ ] Create `website/src/analytics/` - first-party analytics
- [ ] Create `website/src/utils/` - money.js, format.js, etc.
- [ ] Create `website/tests/` and `website/e2e/`

### Phase 5: CI/CD
- [ ] Create `.github/workflows/ci-cd.yml` - offline gates, deployment plan, backend/frontend and live checks
- [ ] Create deploy scripts for each stage
- [ ] Configure OIDC federation with AWS
- [ ] Set up branch protection rules
- [ ] Configure Vercel API publishing without connecting Git integration

### Phase 6: Documentation
- [ ] Fill in `context/business_logic/` docs for each business area
- [ ] Fill in `context/repos/` orientation summaries
- [ ] Fill in `AGENTS.md` with project-specific conventions and invariants
- [ ] Fill in `brand/branding.md` with brand guidelines

---

## Reference: Saasbase Architecture at a Glance

| Dimension | Choice |
|---|---|
| **Cloud** | AWS (setup-selected region; default us-east-2) |
| **Compute** | Lambda (container image, Python 3.13) |
| **API** | API Gateway v2 (HTTP API, $default route) |
| **Database** | DynamoDB (single-table, 3 GSIs) + append-only ledger table |
| **Auth** | Cognito (RS256 JWT) + HMAC device tokens (skeleton) |
| **Payments** | Stripe (skeleton - not wired) |
| **Secrets** | Secrets Manager placeholder/ARN; runtime loading not implemented |
| **Frontend** | Vue 3 SPA on Vercel |
| **State** | Pinia |
| **IAC** | CloudFormation nested stacks (two-phase) |
| **CI/CD** | GitHub Actions + OIDC |
| **Monitoring** | CloudWatch (logs, metrics, alarms) + SNS -> Telegram |
| **Email** | SES (skeleton) |
| **Python style** | Black (100), Ruff (E,F,I,W,UP,B), mypy strict |
| **Testing** | Full pytest/moto + Vitest + local/live Playwright + script/lint gates |
| **AI context** | AGENTS.md + context/ knowledge base |

---

## Industry Standard Recommendations

> **Note:** The Saasbase stack makes specific choices that work well for a small-team product with known access patterns. This section captures where industry standards diverge from those choices for a **generic B2B/B2C SaaS base**. These are recommendations to consider when adapting this stack for a new project, not criticisms of the current architecture.

### 1. IAC: CloudFormation -> Terraform (or AWS CDK)

CloudFormation nested stacks with manual S3 template uploads is the weakest link for a generic base.

**Industry standard: Terraform**
- **HCL** is portable across clouds (AWS, GCP, Azure). State management is mature (remote state in S3 + DynamoDB lock). Every DevOps engineer knows it.
- **Pulumi** is the alternative if you want infrastructure-as-code in real programming languages (TypeScript/Python) with loops, conditionals, and shareable modules - no YAML templating hacks.
- **AWS CDK** is the middle ground: still AWS-only but you write in TypeScript/Python instead of raw YAML.

The two-phase provisioning hack (`DeployLambdas=true/false`) is a CloudFormation workaround for the lack of imperative logic. Terraform handles resource ordering natively via `depends_on` - one `terraform apply`, no manual phases.

**Recommendation:** Terraform with remote S3 backend + DynamoDB lock table. One command deploy. Keep CloudFormation as a lighter-weight option for teams already invested in AWS-only tooling.

### 2. Compute: Add a Container-First Option (Not Lambda-Only)

Lambda via Mangum works but imposes real constraints: cold starts, 15-second timeout ceiling, no native WebSocket support, and 6 MB payload limits.

**Industry standard: Containers as the default, serverless as an option**
- **ECS Fargate** - no cold starts, no timeout ceiling, native WebSocket support. Scales to zero-ish with minimal cost difference at low traffic.
- **Fly.io** or **Render** - even simpler than ECS. Push a Dockerfile, get a URL. Good for early-stage SaaS.
- **Lambda** - keep as an *alternative deployment mode* for bursty, low-traffic APIs or async workers. The Mangum adapter pattern is worth preserving.

A generic SaaS base should document all three paths:

```
# Local:           uvicorn api.main:app
# Lambda:          Mangum(app) -> Lambda handler (low-traffic / async)
# Container:       Dockerfile -> ECS Fargate / Fly.io / Render (general-purpose)
```

**Recommendation:** ECS Fargate as the default recommendation for API workloads. Lambda as a supported alternative for specific use cases.

### 3. Database: PostgreSQL as Default, DynamoDB as Optional

DynamoDB single-table design is elegant but wrong for a *generic* SaaS base:

- **No ad-hoc queries.** You must know every access pattern at design time. Most SaaS products discover their query patterns as they grow.
- **No joins.** Single-table design works around this with denormalization, but it's fragile and creates consistency problems.
- **No schema migrations.** Schema changes mean backfill scripts against every item, not `ALTER TABLE`.
- **Vendor lock-in.** Moving off DynamoDB requires a full data migration. Moving off PostgreSQL is a standard dump-and-restore.

**Industry standard: PostgreSQL**
- **AWS Aurora Serverless v2** - PostgreSQL-compatible, scales to zero, auto-scales with demand. Best of both worlds.
- **Supabase** - managed PostgreSQL with built-in auth, realtime subscriptions, and an S3-compatible storage API. Excellent for early-stage SaaS.
- **Render / Fly.io managed Postgres** - simpler than RDS, good for smaller deployments.

Use **SQLAlchemy 2.0** (async) or **Prisma** (if using TypeScript) as the ORM. Keep the CRUD abstraction layer (`crud.py` -> `backend_flag.py` -> `DynamoCrud | RelationalCrud`) but make `RelationalCrud` the **primary implementation**, with DynamoDB as a supported alternative for teams that know they need single-digit-millisecond latency at scale.

**Recommendation:** PostgreSQL (Aurora Serverless v2) as default. DynamoDB as an opt-in for high-scale, predictable-access-pattern workloads.

### 4. Observability: Add OpenTelemetry from Day One

The current setup has CloudWatch metrics and Telegram alerts. For a production SaaS, observability must be wired in at project creation, not retrofitted.

**Industry standard stack:**
- **OpenTelemetry** - distributed tracing across every service boundary (API -> database -> Stripe -> email). Auto-instrumentation for FastAPI, SQLAlchemy, boto3, httpx.
- **Structured logging** - every log line carries `trace_id`, `span_id`, `user_id`, `request_id`. Use `structlog` (Python) or `pino` (Node.js). Never `print()`.
- **Error tracking** - **Sentry** (or self-hosted **GlitchTip**). Errors are enriched with the local state at the crash point, not just a stack trace. Alerts route to Slack/Teams, not just Telegram.
- **Dashboards** - **Grafana** (with CloudWatch or Prometheus data sources) pre-configured with a default SaaS dashboard: request rate, error rate, p50/p95/p99 latency, DB query performance, Stripe API latency.

**Recommendation:** Ship a `src/observability.py` (or equivalent) that initializes OpenTelemetry, structured logging, and Sentry on app startup. Make it toggleable per-environment so local dev stays lightweight.

### 5. Feature Flags: Separate Configuration from Runtime Toggles

The current config system (`master.py` + `config.py` + env vars) conflates *static configuration* with *runtime feature flags*. These should be separate concerns.

**Industry standard:**
- **LaunchDarkly** - managed, SDKs for every language, percentage rollouts, per-user targeting.
- **Unleash** - self-hosted open-source alternative. Same capabilities, no vendor dependency.
- **Simple DynamoDB/Postgres-backed flag system** - for projects that don't need the full feature set. A `feature_flags` table with `flag_name`, `enabled`, `rules` JSON.

Use cases that every SaaS needs:
- Dark launches (deploy disabled, enable per-tenant when ready)
- Canary releases (roll out to 5% -> 25% -> 100%)
- Kill switches (disable a buggy feature globally without a rollback)
- Per-tenant toggles (enterprise plan gets feature X, starter plan doesn't)

**Recommendation:** Unleash (self-hosted) as the default. Simple DB-backed flags as the lightweight alternative. Keep `config.py` for true static configuration (API keys, table names, timeouts).

### 6. Database Migrations: Versioned Schema Management

DynamoDB doesn't have migrations, but any SQL-based SaaS needs them from day one.

**Industry standard:**
- **Alembic** (SQLAlchemy) - auto-generates migration scripts from model diffs. Versioned, reversible, tested in CI.
- **Prisma Migrate** - if using Prisma as the ORM. Simpler than Alembic but less flexible for complex operations.

Even if staying on DynamoDB, you need a versioned schema approach:
- A `schema_version` attribute on every item.
- Migration scripts that backfill old items on read (lazy migration pattern) or via a batch process.
- A `schema_versions` table tracking which migrations have been applied.

**Recommendation:** Alembic for SQLAlchemy projects. A `migrations/` directory at the repo root with a `README.md` documenting the migration policy (always reversible, always tested, never destructive).

### 7. Multi-Tenancy: Design from Day One

Saasbase is a generic shell (one tenant = the platform for now). Most SaaS products are B2B and need multi-tenancy from the start. Retrofitting tenancy is painful.

**Industry standard patterns:**

| Strategy | Pros | Cons | When to use |
|---|---|---|---|
| **Pool model** (shared DB, `tenant_id` column on every table) | Simple, cheap, easy cross-tenant analytics | Noisy neighbor risk, complex RLS | Early-stage, SMB-focused SaaS |
| **Silo model** (separate DB per tenant) | Strong isolation, easy compliance, independent scaling | Expensive, hard cross-tenant queries | Enterprise, regulated industries |
| **Hybrid** (pool for most, silo for enterprise) | Best of both worlds | Operational complexity | Mid-market and up |

**Implementation in the CRUD layer:**
- Every CRUD function accepts a `tenant_id` parameter.
- The CRUD implementation injects `tenant_id` into every query (WHERE clause or DynamoDB key prefix).
- The auth layer resolves `tenant_id` from the JWT and passes it down.
- Row-level security (RLS) in PostgreSQL as a defense-in-depth layer.

**Recommendation:** Pool model as default. Add `tenant_id` to the standard entity columns. The single-table DynamoDB design already maps well: `pk = TENANT#<id>#ENTITY#<id>`.

### 8. CI/CD: Tests in CI, Preview Environments per PR

The current pipeline runs tests locally (pre-push hooks) and keeps CI deploy-only. For a generic SaaS base, this is risky - nothing prevents pushing broken code.

**Industry standard:**
- **Tests run in CI** on every push and PR. The pre-push hook is a convenience, not a gate.
- **Preview environments per PR** - Vercel does this automatically for the frontend. For the backend, use **SST** (Serverless Stack) or a per-branch CloudFormation/Terraform stack that tears down on PR close.
- **Trunk-based development** with feature flags for incomplete work. No long-lived feature branches.
- **Linear history** - squash-merge PRs to `main`, rebase before merging.

**Recommendation:** Add a `test` job to the GitHub Actions workflow that runs on every PR. Add preview environment provisioning as a follow-up (it's infrastructure-heavy but worth it for team velocity).

### 9. API Versioning: Documented Deprecation Policy

The current `/v1/` prefix is good practice, but a generic SaaS base needs a documented strategy for when and how versions change.

**Industry standard:**
- **URL-path versioning** (`/v1/`, `/v2/`) - simplest for REST APIs. Explicit and visible.
- **Header-based versioning** (`Accept: application/vnd.api+v2+json`) - cleaner URLs but harder to discover and test.
- **No versioning (evolve compatibly)** - only works for internal APIs or when you control all clients. Not realistic for a public SaaS.

**Deprecation policy template:**
- Minor, non-breaking additions -> add to current version, no bump.
- Breaking changes -> new major version (`/v2/`). Old version supported for **6 months** with deprecation notices in response headers (`Sunset: Sat, 31 Dec 2026 23:59:59 GMT`).
- Emergency security fixes -> backported to supported old versions.
- Version count: maximum **2 live versions** at any time (current + previous).

**Recommendation:** URL-path versioning. Document the deprecation policy in `context/dev_guides/api-versioning.md`. Add a `Deprecation` response header middleware.

### 10. Summary: Recommended Stack for a Generic SaaS

| Dimension | Saasbase (Current) | Recommended for Generic SaaS Base |
|---|---|---|
| **IAC** | CloudFormation nested stacks | **Terraform** (multi-cloud) or **AWS CDK** (AWS-only) |
| **Compute** | Lambda + Mangum only | **ECS Fargate** (default) + Lambda (alternative) |
| **Database** | DynamoDB single-table | **PostgreSQL** (Aurora Serverless v2) with DynamoDB as option |
| **Backend** | FastAPI + Mangum | FastAPI + optional Mangum/container adapters |
| **Frontend** | Vue 3 SPA on Vercel | Vue 3 SPA on Vercel (or Nuxt 3 for SSR) |
| **CI/CD** | GitHub Actions + OIDC | GitHub Actions + OIDC + **preview envs per PR** + **tests in CI** |
| **Observability** | CloudWatch + Telegram | **OpenTelemetry** + Sentry + structured logging |
| **Feature flags** | None | **Unleash** (self-hosted) or DB-backed flags |
| **Migrations** | N/A (DynamoDB) | **Alembic** or Prisma Migrate |
| **Multi-tenancy** | N/A (single-tenant shell) | Pool model with row-level security in CRUD layer |
| **API versioning** | `/v1/` only | `/v1/` + documented deprecation policy |
| **CRUD abstraction** | ✅ Keep | ✅ Keep (make SQL the primary impl) |
| **Mock-first frontend** | ✅ Keep | ✅ Keep |
| **Context/ knowledge base** | ✅ Keep | ✅ Keep |
| **Money/time conventions** | ✅ Keep | ✅ Keep |

### Principles That Survive Any Stack Change

These patterns from the Saasbase codebase are worth preserving regardless of technology choices:

1. **CRUD abstraction layer** - `backend_flag.py` pattern that lets you swap database backends without touching business logic.
2. **Mock-first frontend development** - a complete backend mock in the frontend repo means the UI team never blocks on the API team.
3. **`context/` knowledge base for AI-assisted development** - the three-layer system (`AGENTS.md` -> `context/` -> tests) will become the standard way to structure codebases as AI coding agents mature.
4. **Single error boundary** - all exceptions caught at one place, translated to a consistent error envelope. No scattered try/except.
5. **Money as integer minor units** - never floats. Always paired with ISO-4217 currency codes. Non-negotiable for anything touching payments.
6. **ISO-8601 UTC timestamps** - lexicographically sortable strings. No timezone ambiguity.
7. **Validate at boundaries only** - Pydantic at the route level. Internal callers are trusted.
8. **Optimistic locking** - `version` field on every entity. Prevents silent overwrites in concurrent systems.
