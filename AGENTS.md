# Saasbase - Agent Instructions

## Product context

Generic SaaS shell, not yet a defined product. Native Cognito auth and owner-scoped
sample items work; application requirements are not populated.
When the owner defines the app, replace this summary with its purpose, users,
approved MVP and links to [business requirements](context/business_logic/README.md).
Do not invent product decisions or treat a proposed plan as implemented behavior.

## Read before acting

- [README.md](README.md): operating manual, commands, capabilities and limits.
- [coding-rules.md](context/dev_guides/coding-rules.md): implementation and acceptance rules.
- [Developer guide index](context/dev_guides/README.md) and [testing guide](context/dev_guides/testing.md).
- [saas-techstack-guide.md](context/dev_guides/saas-techstack-guide.md): architecture.
- [Handoff prompt](context/onboarding/run-this-prompt-after-setup.md): initial requirements/approval workflow.
- Relevant [business documents](context/business_logic/) and [approved plans](context/plans/).
- Relevant orientation: [backend](context/repos/backend.md),
  [website](context/repos/website.md), [infrastructure](context/repos/aws-infra.md).

## Implementation map

| Concern | Location |
|---|---|
| HTTP validation/auth/response | `backend/api/schemas/`, `routers/`, `auth/` |
| Business rules -> storage | `backend/api/services/` -> `crud/crud.py` -> database backend |
| UI, state and navigation | `website/src/views/`, `components/`, `stores/`, `router/` |
| Shared HTTP, mock UI and text | `website/src/api/client.js`, `mocks/`, `i18n/locales/` |
| Infrastructure / IAM | `iac/main.yaml`, `iac/templates/`, `aws/` |
| Operations / live checks | `scripts/`, `setup-scripts/` |
| Local config / deployment flags | `config/`; secrets stay ignored |
| Brand / product docs | `brand/`, `context/business_logic/` |

FastAPI/Python 3.13 runs locally with Uvicorn and on Lambda with Mangum;
Vue 3/Pinia/Router/i18n/Axios builds on Node 22 and publishes to Vercel.
DynamoDB is implemented; relational storage and payments are not finished.

## Map important features into context

Every important feature/change must have discoverable documentation:
- Developer workflows, testing, configuration and technical practices ->
  `context/dev_guides/`.
- Product behavior, rules, roles, data and acceptance criteria ->
  `context/business_logic/`.
- Changes to a repo/component's architecture, structure, responsibilities or
  operating model -> `context/repos/` and the relevant technical guide.
- Proposed work/decisions and implementation order -> `context/plans/`;
  initial handoff instructions -> `context/onboarding/`.

Choose useful subfolders at your discretion. Reuse/update existing documents,
keep category indexes and relevant AGENTS links current, and cross-link features
that span categories. Document implemented behavior separately from proposals.
Do not duplicate whole guides or leave important features discoverable only in code.

## Required workflow

1. Inspect code and relevant requirements; ask about material ambiguity.
2. Make small, complete changes using existing patterns; do not invent APIs/fields.
3. Add unit, integration/API and browser tests at every applicable layer:
   `backend/tests/`, `website/tests/unit/`, `website/e2e/`.
   Extend `website/e2e/deployed/` and `setup-scripts/test-shell.ps1` for live flows.
4. Update applicable mocks and the context map above; new suites join CI
   and the full runner. Explain genuinely inapplicable layers.
5. Run **all** local suites/build/lint: `./scripts/test.ps1` or
   `bash ./scripts/test.sh` from root. Report exact results and remaining gaps.
6. When deployment is authorized, verify the app's Actions run and real dev checks.
   Mocks, successful builds and skipped jobs are not live deployment evidence.

`dev` deploys protected Preview; `main` deploys Production; PRs only test.
All offline suites gate deployment by default. Explicit user pipeline skips in
`config/override.env` do not replace full local acceptance or prove verification.
The separate live website/API job runs after deployment by default; temporary-user
auth is required on dev when it runs. Production opts in with `RUN_AUTH_SMOKE_TESTS=true`.
Never charge customers, mutate their data or send messages as test side effects.
Setup is new-repo-only; destroy/purge permanently delete data and require explicit
authorization. Never use them as part of ordinary feature development.
Confirmed purge attempts independent deletions and reports/journals all failures;
ownership/active-deployment gates remain mandatory. Keep journals for safe retries.
For approved IAM permission changes on an existing app, use `scripts/update-iam.ps1`
or `scripts/update-iam.sh`, not setup; it requires the original `.setup/state.json`.
Setup seeds an empty repo with `[skip ci]`, launches main/dev pipelines in parallel
and requires both to pass. First Preview upload waits for ready Vercel Production;
it preserves cloned history but does not use GitHub template-generation metadata.

## Invariants

- Only CRUD touches the database; services do not call DynamoDB directly.
- Preserve ownership/role checks and optimistic locking on entity updates.
- Money = integer minor units + ISO-4217; timestamps = ISO-8601 UTC strings.
- Backend errors propagate to `backend/api/main.py`; no catch-and-swallow.
- Secrets stay out of code/git/logs/frontend; tokens stay in memory, not storage.
- If payments are added, only verified Stripe webhooks may mark payments paid.
- Python: Black 100, Ruff `E,F,I,W,UP,B`, mypy strict; follow existing JS conventions.
- If business docs and code disagree, report it: code describes current behavior,
  documents intended behavior. Ask before changing one to match the other.
