# Saasbase

An AI-first SaaS shell: FastAPI on AWS Lambda, DynamoDB, Cognito and Vue 3 on
Vercel. Start with [setup.md](setup.md), then use
[run-this-prompt-after-setup.md](context/onboarding/run-this-prompt-after-setup.md) to define your app.

## What this shell provides

This is a working technical foundation, not a finished product. Setup creates
a private application repository, configures AWS/GitHub/Vercel, and deploys
separate development and Production backends with a Vue website for each.

- Native email/password registration, email-code confirmation/resend and login.
- Protected navigation, in-memory sessions, token refresh and visible API errors.
- Public service/health endpoints and authenticated identity/admin checks.
- A sample owner-scoped `item` API: create, get, list, versioned update and soft
  delete. It demonstrates the pattern to follow for product features.
- Shared database access, request validation, error envelopes, CORS, security
  headers and deployment scripts.
- Structured offline tests and post-deployment API/browser checks.

There are no product requirements, payment flows, tenant model or completed
external integrations yet. Do not mistake placeholders for implemented features.
See [shell limits](#local-development-and-shell-limits) before planning a product.

## The five entry documents

| Document | Responsibility |
|---|---|
| [README.md](README.md) | Human operating manual: capabilities, usage, workflow, tests and recovery |
| [AGENTS.md](AGENTS.md) | Compact, durable AI context: product summary, code map, commands and invariants |
| [run-this-prompt-after-setup.md](context/onboarding/run-this-prompt-after-setup.md) | One-time prompt to turn your idea into requirements and approved plans |
| [coding-rules.md](context/dev_guides/coding-rules.md) | Required implementation practices and acceptance checks |
| [saas-techstack-guide.md](context/dev_guides/saas-techstack-guide.md) | Detailed architecture and technical extension patterns |

Product behavior belongs in [context/business_logic](context/business_logic/).
Approved implementation plans belong in [context/plans](context/plans/).
The documents above explain how to work; they do not replace product requirements.

## From shell to application

1. Follow [setup.md](setup.md) for accounts, then run `./setup.ps1` or
   `bash ./setup.sh` from the already-cloned shell. Setup installs its own missing
   tools; it does not install the complete local development toolchain.
2. Choose an unused app name and finish setup. It changes Git origin in this
   folder, preserves local files and does not rename the folder.
3. Open the printed main/dev Actions runs and app URLs. A completed deployment
   must include successful tests, the selected deploy steps and live checks;
   a green workflow containing skipped deploy steps is not enough.
4. Paste the [handoff prompt](context/onboarding/run-this-prompt-after-setup.md)
   with your idea into your preferred AI agent. It gathers requirements, updates
   the product documents and AGENTS, then requests approval before planning or
   implementing.
5. Implement approved features on `dev` or feature branches targeting `dev`.
   Pull requests run tests without deployment. Push/merge to `dev` deploys Preview;
   promote reviewed changes to `main` to deploy Production.

Never run setup again to deploy an existing app. Use its normal GitHub workflow.
No branch promotion or synchronization happens automatically after onboarding.

## Repository contract

- [AGENTS.md](AGENTS.md) is the AI entry point; keep product context and links there.
- [Coding rules](context/dev_guides/coding-rules.md) define implementation and testing requirements.
- Every feature includes unit, integration/API and browser coverage for its
  applicable behavior, with happy paths, authorization and meaningful failures.
  No feature is complete based only on mocks or a build.
- Run the entire local test suite before handoff. CI runs all offline suites
  by default on main/dev pushes and pull requests, regardless of changed folders.
  Explicit pipeline skips are a user choice, not evidence of feature acceptance.
- Real deployed API and browser checks run after deployment. Authenticated checks
  run by default on dev and opt-in on Production; see pipeline overrides below.
- Requirements and approved plans belong in [context](context/), not ad hoc
  duplicated documents. Follow the existing folder structure.
- Map every important feature into context: developer practices in
  [dev_guides](context/dev_guides/README.md), product behavior in
  [business_logic](context/business_logic/), and component/architecture changes
  in [repos](context/repos/). Choose useful subfolders, update indexes and
  cross-link features spanning categories.

## Structure

| Location | Purpose / test ownership |
|---|---|
| [backend/api](backend/api/) | Routers -> services -> CRUD -> DynamoDB |
| [backend/tests](backend/tests/) | Unit, router/API and integration tests (including moto-backed storage) |
| [website/src](website/src/) | Vue app, native Cognito auth and API client |
| [website/tests/unit](website/tests/unit/) | Vitest component/store/helper tests |
| [website/e2e](website/e2e/) | Local Playwright workflows, including mocked native-auth boundaries |
| [website/e2e/deployed](website/e2e/deployed/) | Real deployed browser checks; no mocked network responses |
| [iac/tests](iac/tests/) | Infrastructure deployment-script regressions |
| [setup-scripts/tests](setup-scripts/tests/) | Setup, purge, publishing and smoke-runner regressions |
| [setup-scripts/test-deployment.py](setup-scripts/test-deployment.py) | Live test orchestration and temporary test-user lifecycle |
| [setup-scripts/test-shell.ps1](setup-scripts/test-shell.ps1) | Live API contracts, authorization and isolated CRUD |
| [context](context/) | Architecture, business requirements and approved plans |
| [context/onboarding](context/onboarding/) | Post-setup application handoff |
| [scripts](scripts/) | Test, IAM update, destroy and purge entry points |
| [config](config/) | Local environment template, optional setup choices and deployment overrides |
| [iac/templates](iac/templates/) | Service-specific CloudFormation resources |
| [aws](aws/) | Bootstrap GitHub deployment IAM policy and trust example |
| [brand](brand/) | Naming, visual guidelines and assets |
| [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) | Offline gates, deployment selection and live verification |

Keep tests in their owning suite; extend existing fixtures/helpers instead of
creating parallel test frameworks. Add new suites to both the full-suite runner
and CI so they cannot be forgotten.

## Where to implement a feature

Read the relevant [orientation](context/repos/) and business requirements first.
Use the existing item flow as a reference, not a second parallel framework.

| Change | Implementation locations | Required applicable tests |
|---|---|---|
| Data or business rule | [schemas](backend/api/schemas/), [services](backend/api/services/), [CRUD](backend/api/crud/) | Backend unit/service and storage/integration cases |
| HTTP contract | [routers](backend/api/routers/), [auth](backend/api/auth/), [error boundary](backend/api/main.py) | Router/API status, payload, auth/ownership and version-conflict cases |
| Page or interaction | [views](website/src/views/), [components](website/src/components/), [router](website/src/router/), [stores](website/src/stores/) | Frontend unit and browser happy/error/protected-navigation cases |
| API-backed UI | [API client](website/src/api/client.js), [mocks](website/src/mocks/), [locales](website/src/i18n/locales/) | Mock flow, native-auth browser flow and real deployed API/browser path |
| Infrastructure or configuration | [IaC](iac/), [IAM](aws/), [setup/deploy scripts](setup-scripts/) | Script regressions, schema lint and explicit deployment verification |

Backend requests flow **router -> service -> CRUD -> DynamoDB**. Routers validate
HTTP inputs; services own business decisions; only CRUD accesses the database.
Frontend views use the shared client/stores, not ad hoc authentication or fetch
logic. Preserve localization, integer money, UTC strings and versioned updates.

For each feature: agree on observable behavior, add meaningful tests, implement
the complete API/UI path, update applicable mocks/docs, run all local suites,
then verify the deployed dev workflow when deployment is authorized. Record
remaining gaps rather than declaring untested integrations complete.

## Pipeline and first deployment

| Branch | AWS environment | Vercel | Authenticated live tests |
|---|---|---|---|
| `main` | `prod` | Public Production | Explicit opt-in |
| `dev` | `dev` | Protected Preview | Default; explicit whole-job skip available |

1. **Check changes and overrides** resolves changed infrastructure/backend/frontend
   components and explicit test flags before any test jobs. PRs never deploy.
2. Infrastructure/script checks, CloudFormation schema lint, the entire backend
   pytest suite, frontend unit tests and both local browser suites run by default.
   Failed enabled checks block deployment; intentionally skipped suites do not.
3. First deployments, manual dispatches, `FORCE_ALL`, or IaC changes run both
   CloudFormation phases. Backend-only changes skip stateful provisioning and
   template uploads, build/push the image, and update its CloudFormation-managed
   image parameters using the existing nested templates. This avoids image drift
   from direct Lambda updates. Selected websites build against the real API/Cognito
   configuration and publish afterward.
4. **Test deployed website and API** is a separate job after deployment succeeds.
   Public API contracts, anonymous browser routing, health, CORS and CSP are
   checked. On dev (or opted-in prod), real login, non-admin authorization,
   request validation and isolated item CRUD/version conflicts must also pass.
5. Any failed check or cleanup fails the deployment. Green skipped steps do not
   prove a working deployment.

Setup creates an **empty** private repo, adds a `[skip ci]` initialization commit
to the cloned shell's existing history, and seeds main. It creates dev at that
same skipped commit, so neither initial branch triggers push-based CI.
GitHub's template-generation API is not used: the app preserves the cloned
files/history but has no "generated from template" repository metadata.
After configuration it starts the complete main and dev pipelines without waiting
between dispatches: exactly two intentional setup runs, running in parallel.
Setup waits for both to pass. Only the first Preview upload waits for a ready
Production website (up to 20 minutes), avoiding Vercel's first-deployment promotion.
Their tests, AWS deployments and website builds can proceed concurrently.
Both initial dispatches deploy both components. Setup prints both Actions links
as runs start, and application URLs after successful completion. If one fails,
setup reports failure; the other pipeline may still be running.

Each Vercel website is built automatically with its own stage's API endpoint,
Cognito issuer/client and exact API/Cognito CSP origins; no manual API URL entry
is required. Main uses the prod API; dev uses the dev API.

Ongoing deployments do not synchronize branches or require a promotion PAT.
Documentation-only changes still run offline tests, but may not need deployment.
`config/override.env` can override deployment selection; setup rejects enabled deployment
and test skip flags because initial setup must deploy and verify both environments.

### Pipeline overrides

Uncomment the flags you want in [config/override.env](config/override.env), then
commit/push them. All test skips default to `false`.

| Flag | Skips |
|---|---|
| `SKIP_TEST_INFRASTRUCTURE=true` | Script regressions and CloudFormation schema lint |
| `SKIP_TEST_BACKEND=true` | Backend unit, API and storage-integration pytest suites |
| `SKIP_TEST_WEBSITE_UNIT=true` | Frontend unit tests |
| `SKIP_TEST_WEBSITE_E2E=true` | Local mock-first browser workflows |
| `SKIP_TEST_WEBSITE_AUTH=true` | Local native-auth browser workflows |
| `SKIP_POST_DEPLOY_TESTS=true` | The entire live website/API job, on either stage |

These flags are independent of deployment selection. `SKIP_ALL` skips deployments,
not tests; `FORCE_ALL` forces full infrastructure/backend/website deployment, not
skipped tests. Deployment readiness checks still run. The changes job logs warnings
and an Actions summary for disabled suites: skipped means **not verified**.
The full local acceptance scripts ignore these flags and always run every suite.

## Live test isolation and Production opt-in

Each authenticated deployment run creates a new non-admin Cognito user with a
generated password. Account email delivery is suppressed; credentials stay in
memory and are masked in Actions logs. No persistent test password, customer
account or extra GitHub token is required. API tests soft-delete only their own
created item; DynamoDB records remain. The temporary Cognito user is deleted in
cleanup, including when tests fail. Forced runner termination can interrupt
cleanup and leave test users/items; do not claim automatic cleanup in that case.

Real browser checks exercise native login, authenticated data loading and
session loss on reload. Local mocked-browser tests also cover registration,
confirmation/resend, refresh and auth errors. Automated provisioning does **not**
test real email delivery or the user's inbox verification process.

Unless the entire live job is explicitly skipped, Production public/read-only
checks run after every selected deployment. To opt in to temporary-user
authenticated tests and isolated test writes, set **GitHub > Settings >
Environments > prod > Environment variables > RUN_AUTH_SMOKE_TESTS = true**.
Set it to `false` to opt out again. This variable does not disable dev authentication
when the live job runs; `SKIP_POST_DEPLOY_TESTS` skips the entire job explicitly.
Never add real charges, customer messages/data mutations or destructive admin
operations to tests without separate approval.

The dev protection bypass is attached only to requests to the configured Vercel
website origin, never to AWS/Cognito. Browser traces, videos and screenshots
are disabled for live credentials. The deployment role's Cognito test permissions
are scoped to the selected account/region; the runner selects only the exported
environment pool and its newly created user.

## Run all local tests

See the [testing guide](context/dev_guides/testing.md) for fixture ownership,
feature test design, troubleshooting and live-vs-mocked evidence.

Development requires Python 3.13, Node.js 22, PowerShell 7.2+, Bash and cfn-lint.
On Windows use Git Bash; the runner avoids a `bash` executable backed by an
unconfigured WSL installation. Before backend checks, the runner verifies the
Python interpreter satisfies `requires-python` (>= 3.13). In your development
Python environment, from the repository root:

```sh
python -m pip install -r backend/requirements-dev.txt
python -m pip install cfn-lint==1.57.2
```

Then, from `website`:

```sh
npm ci
npx playwright install --with-deps chromium
```

CI installs these dependencies independently. The full-suite script does not
install tools or silently skip missing suites.

From the repository root:

```powershell
./scripts/test.ps1
```

```sh
bash ./scripts/test.sh
```

The runner executes PowerShell setup/purge/smoke regressions, Bash deployment/
planner/installer tests, all backend pytest tests, the backend quality gates
(Python version, Ruff, Black and mypy strict via `scripts/python-check.sh`),
all frontend unit tests, both local Playwright suites, a production frontend
build and CloudFormation lint.
It fails on missing tools or failed checks; it never deletes live resources.
Live tests require deployed infrastructure and run separately in the pipeline.

| Suite | Command / location | What it proves |
|---|---|---|
| Backend unit, service, API and storage integration | `python -m pytest --import-mode=importlib` in `backend` | Contracts through FastAPI/TestClient and moto-backed storage; not live AWS |
| Backend quality gates | `scripts/python-check.sh` in root | Python >= 3.13, Ruff, Black and mypy strict, enforced by the runner and CI |
| Frontend unit | `npm run test:unit` in `website` | Store/client/helper behavior |
| Local browser | `npm run test:e2e` in `website` | Shell workflows with local backend mocks |
| Native-auth browser | `npm run test:e2e:auth` in `website` | Native forms/session handling with Cognito responses mocked |
| Setup, operation and deployment scripts | Included in `scripts/test.ps1` | Targeting, argument forwarding, errors and cleanup using fixtures |
| Deployed API/browser | `setup-scripts/test-deployment.py`, invoked by CI | Actual configured API, website and Cognito after deployment |

The backend fixture supplies isolated tables and signed test identities. Browser
fixtures start their own local servers. The full runner sets `CI=true` so browser
suites do not reuse an unrelated server. No local suite deletes cloud resources.
Live suites are separate: discovering tests or passing mocks does not prove they
passed against AWS/Vercel.

Use targeted commands for iteration, but finish with `./scripts/test.ps1` or
`bash ./scripts/test.sh`. New suites must be wired into that runner and CI.
Coverage is diagnostic, not a substitute for behavioral acceptance.

## Local development and shell limits

DynamoDB table/GSI queries collect all pages on the server, including the 1 MB
page boundary. The item-list API still returns one complete owner-scoped array;
`limit` controls database batch size, not total results. See
[backend query behavior](context/repos/backend.md#dynamodb-query-pagination) for
resource limits and future application-level pagination.

Copy [config/.env.example](config/.env.example) to `config/.env` and configure
local values. Never commit it.

**UI-only development:** from `website`, run `npm run serve` and open
`http://localhost:8080`. Backend mocks are on by default; this mode does not
require a running API or prove real authentication/storage works.

**Real API development:** install `uvicorn` in your development Python environment
(it is not included in the current dev requirements). From `backend`, run
`uvicorn api.main:app --reload --env-file ../config/.env`.
The API uses `http://127.0.0.1:8000`; `/health` and `/docs` are available locally.
Authenticated/storage workflows need configured Cognito/DynamoDB and AWS access;
there is no automatic local AWS emulator. Pytest uses its own moto fixtures.

To connect the local website, copy [website/.env.example](website/.env.example)
to `website/.env.local`, set `VUE_APP_ENABLE_MOCKS=false` and
`VUE_APP_API_BASE=http://127.0.0.1:8000`, and supply
`VUE_APP_COGNITO_ISSUER` / `VUE_APP_COGNITO_CLIENT_ID` for the chosen environment.
Restart `npm run serve` after changing build-time variables. Match API CORS to
the actual website origin. Only public API/Cognito configuration may reach a
frontend bundle; never expose AWS/Vercel credentials or server secrets.

Optional setup choices belong in `config/setup.env`; keep credentials local and
never commit `config/.env`. Personal Git pull/push helpers are local-only,
ignored by Git and not part of the template or CI.

Native registration, verification and login are included. Tokens are kept only
in memory; reload requires login. Password-reset/MFA screens, application-specific
business logic, payments and runtime secret loading still require implementation.
Cognito email delivery/quotas depend on the AWS account. Setup does not configure
custom domains or populate application secrets. The relational CRUD option is a
stub, not a working SQL backend. Device/anonymous auth and integration helpers do
not provide finished product workflows. Tenant isolation, subscriptions, webhooks
and migrations need explicit requirements, implementation and tests.

## Operations and failure recovery

Setup never reuses repositories or deletes existing app resources. Name collisions
hard-fail; choose another name. A race/failure after repo creation can leave a
partial installation. Do not rerun setup against an existing repo.

- Inspect the linked Actions run. CloudFormation failures print root/nested
  stack events; an existing templates bucket message alone is not a failure.
- To renew a Vercel token, run `pwsh -File setup-scripts/save-vercel-token.ps1`,
  then update `VERCEL_TOKEN` in both GitHub environment secrets for existing apps.
  Verify deployment before revoking the old token.
- Preview protection failures: compare Vercel **Deployment Protection > Protection
  Bypass for Automation** with dev's `VERCEL_AUTOMATION_BYPASS_SECRET`.
- After changing [aws/iam.json](aws/iam.json), update existing app permissions:
  Windows: `./scripts/update-iam.ps1`; macOS/Linux: `bash ./scripts/update-iam.sh`.
  Run from the original setup folder (its ignored `.setup/state.json` identifies
  the app/account/region), accept the AWS profile and type `UPDATE`.
  The script installs missing tools, signs in when needed, verifies the linked
  repository and role ownership, then replaces only the app's deploy inline
  policy using setup's renderer. It affects both dev and Production; trust,
  other policies and infrastructure are unchanged. `-Plan` previews without
  writing; `-AWSProfile name` selects another local administrator profile.
  Rerun the existing app workflow afterward. Setup remains new-repo-only.

Use [setup.md](setup.md#scripts) for destroy/purge commands and permanent-loss
warnings. Destroy removes only app CloudFormation resources (including retained
data), pauses Vercel Production, and keeps repo/bootstrap resources. A later
deployment recreates **empty** infrastructure, not old users, data or secrets.

Purge deletes the app repo, matching Vercel projects and app AWS stacks/orphans,
including the templates bucket and app roles. It inventories exact naming
patterns, excludes known foreign ownership, drains CI, verifies AWS/Vercel removal,
and deletes GitHub last. Scope is the selected AWS account/region and Vercel team;
IAM roles are account-global. Shared OIDC, unrelated names, backups and local
files remain. Residual subscriptions/storage can still cost money.
Purge reuses the same encrypted Vercel token vault as setup. Workspace selection
uses an explicit `-VercelTeamId`, an unfinished purge record, matching local setup
state, or configured/environment `VERCEL_TEAM_ID`, in that order. Otherwise it
discovers visible teams with the token, auto-selecting one or asking for a numbered
choice. Deleted repos/projects are tolerated after absence checks; API access
errors are reported rather than silently skipping a provider.

After confirmation and CI shutdown, purge continues independent AWS resource,
Vercel project and GitHub deletion attempts even when another deletion fails.
GitHub deletion is attempted last, not conditioned on AWS/Vercel success. The
final error lists failed/unverified targets and saves them in the incomplete
purge record; retries tolerate successful earlier deletions. Active workflows,
changed identities and ownership checks remain safety gates. If AWS inventory
cannot be verified, AWS stays untouched while separately verified Vercel/GitHub
targets can still be deleted after confirmation. `-Plan` reports incomplete
inventory as an error without deleting anything. Ordinary destroy and setup
collision checks remain fail-fast.

Keep `.setup/purge-*.json` or `.setup/teardown.json` after interrupted deletion;
retry the same destructive command and identity. Failures may leave workflows
disabled; replacement-resource checks prevent an old record deleting a new app.
Purge checks reported OAuth scopes for `delete_repo` before any cloud mutation
when the repository exists. Account admin rights alone do not grant that token
scope. Run `gh auth refresh -h github.com -s delete_repo` if missing. Tokens without
OAuth scope headers cannot have deletion permission preverified; fine-grained
tokens need repository Administration write permission. Environment tokens must
be updated separately, and organization restrictions can still block deletion.
GitHub deletion failure retains an incomplete purge record for retry and does
not undo completed AWS/Vercel deletions.
Workflow shutdown skips already-disabled workflows; an inactive-workflow race
is accepted only after rechecking its state. For a deleted nested stack lacking
`RootId`, teardown can verify its ancestry through the actual historical parent
stack inventories. Unavailable/foreign ancestry still blocks AWS cleanup and
now reports the exact resource and stack IDs; it is not proof of an S3 failure.
These records are not a way to bypass setup's no-reuse policy.
